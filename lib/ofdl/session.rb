# frozen_string_literal: true

module OFDL
  Summary = Data.define(:downloaded, :skipped, :protected, :failed, :bytes) do
    def self.empty = new(downloaded: 0, skipped: 0, protected: 0, failed: 0, bytes: 0)

    def add(outcome)
      with(
        downloaded: downloaded + (outcome.status == :downloaded ? 1 : 0),
        skipped: skipped + (outcome.status == :skipped ? 1 : 0),
        protected: protected + (outcome.status == :protected ? 1 : 0),
        failed: failed + (outcome.status == :failed ? 1 : 0),
        bytes: bytes + outcome.bytes
      )
    end

    def merge(other)
      with(
        downloaded: downloaded + other.downloaded,
        skipped: skipped + other.skipped,
        protected: protected + other.protected,
        failed: failed + other.failed,
        bytes: bytes + other.bytes
      )
    end

    def total = downloaded + skipped + protected + failed
  end

  # Wires the pieces together and owns the run.
  #
  # Built lazily so `ofdl status` can report the environment and the library
  # before `jar` brings up the Keychain prompt, and so an auth failure surfaces
  # before any enumeration starts.
  class Session
    attr_reader :config, :log, :stats

    # Creators and sources whose newest post older than `--since` is not on
    # disk; see #note_gap.
    attr_reader :gaps

    def initialize(config:, log:, stats: Stats.new, preview: nil)
      @config = config
      @log = log
      @stats = stats
      @preview = preview
      @gaps = []
    end

    # The dashboard, once it exists; workers draw their own previews through it.
    attr_writer :preview

    def jar = @jar ||= Cookies.load(profile: @config.chrome_profile)

    def rules_source = @rules_source ||= RulesSource.new(config: @config, log: @log)

    def rules = @rules ||= rules_source.load

    def signer = @signer ||= build_signer(rules)

    def transport
      @transport ||= Transport::CurlImpersonate.newest_chrome(binary: @config.curl_impersonate, log: @log)
    end

    # Handed to the Client so a rejected signature can be retried with freshly
    # fetched rules exactly once.
    def refresh_signer!
      @rules = rules_source.refresh!
      @signer = build_signer(@rules)
    end

    def site_state
      @site_state ||= SiteState.new(transport:, auth_id: jar.auth_id, log: @log)
    end

    def client
      @client ||= Client.new(
        jar:, signer:, transport:, site_state:, stats: @stats,
        rate_limiter: RateLimiter.new(@config.requests_per_second),
        log: @log,
        refresh_signer: -> { refresh_signer! }
      )
    end

    def api = @api ||= Api.new(client:)

    def library = @library ||= Library.new(root: @config.output_dir, log: @log)

    def scratch = @scratch ||= Scratch.new

    def downloader
      @downloader ||= Downloader.new(library:, config: @config, log: @log, transport:,
                                     scratch:, stats: @stats, preview: @preview)
    end

    # Enumeration and downloading run at the same time: the producer pushes each
    # item onto the queue as it is discovered and the download pool consumes it.
    #
    # The queue is bounded, or enumeration would race ahead of the downloads and
    # hold the whole timeline in memory.
    # One queue and one pool for the whole run. The producer walks every creator
    # without waiting for the previous one's downloads to drain, so a creator
    # boundary costs nothing.
    #
    # A worker can therefore be fetching for a creator other than the one being
    # scanned, so the username travels on the queue beside its item instead of
    # being closed over.
    # How far the library walk has got, so the producer can wait for one
    # creator instead of for the whole tree.
    def counted = @counted ||= Watermark.new.finish

    # `on disk` is read from the tree rather than accumulated as items are
    # listed. `only` is passed to Library#tally, which documents it.
    #
    # The walk gets its own thread. The walk is filesystem-bound and the
    # listing the walk overlaps is paced at `requests_per_second`, so the walk
    # runs in the gaps between requests.
    #
    # The producer will not list a creator the walk has yet to pass, so no
    # worker writes into a directory the walk has still to read. A file written
    # ahead of the walk would be counted into `on_disk` by the walk and into
    # `downloaded` by the worker, and Dashboard#header_lines adds the two.
    #
    # Counting per file rather than per directory keeps the figure climbing at
    # the dashboard's refresh rate on a large library.
    #
    # Returns the thread doing the walk.
    def count_library(only: nil)
      # The thread holds its own reference: were it to read the ivar, a second
      # count_library would have this thread's finish release the new
      # watermark, and the producer would stop waiting for the walk.
      counted = @counted = Watermark.new
      Thread.new do
        library.tally(only:, on_creator: ->(name) { counted.pass(name) }) do |files, bytes|
          @stats.bump(:on_disk, files).bump(:on_disk_bytes, bytes)
        end
      rescue StandardError => e
        @log.warn("library count: #{e.class}: #{e.message} -- continuing without it")
      ensure
        counted.finish
      end
    end

    # The order Library#tally walks the tree in. Taking the creators in that
    # order is what makes wait_for_count almost always free: the walk is ahead
    # of the listing from the first creator, and stays ahead. Public because
    # the CLI announces the run in this order before archive starts.
    def in_walk_order(targets) = targets.sort_by { library.walk_key(it[:username]) }

    def archive(targets:, sources: @config.sources, since: nil, skip_ads: @config.skip_ads?)
      queue = SizedQueue.new(QUEUE_DEPTH)
      summary = Summary.empty
      tally = { done: 0, bytes: 0 }
      mutex = Mutex.new

      # A worker keeps its slot for the whole run. The slot is its row in the
      # panel and its slice of the image zone, so neither is allocated.
      consumers = Array.new(@config.concurrency) do |slot|
        Thread.new do
          while (job = queue.pop)
            item, username = job
            @stats.bump(:queued, -1)
            outcome = consume(item, username:, slot:)
            @stats.record(outcome)
            mutex.synchronize do
              summary = summary.add(outcome)
              tally[:done] += 1
              tally[:bytes] += outcome.bytes
              report(outcome, tally, username)
            end
          end
        end
      end

      produce(queue, targets:, sources:, since:, skip_ads:)
      @stats.done_scanning
      consumers.each(&:join)
      @log.clear_progress
      summary
    end

    # Yields each item the moment it is found. Deduplicated across sources: the
    # same media often appears in both a timeline and the paid feed.
    def stream(user_id:, sources:, since: nil, username: nil, seen: Set.new, skip_ads: @config.skip_ads?)
      sources.each do |source|
        @log.step("#{"#{username} " if username}#{source}")
        @stats.scanning(creator: username, source:)
        counts = Hash.new(0)

        each_row(source, user_id, since:) do |row|
          counts[:rows] += 1
          # Read once per row rather than once per item, and only when the
          # answer would be acted on.
          advert = skip_ads && Advert.reason(row, creator: username)

          Media.from_row(row, source:).each do |item|
            counts[:media] += 1
            count_discovery(item)

            verdict = verdict_for(item, username:, since:, seen:, advert:)
            counts[verdict] += 1
            case verdict
            when :old then note_gap(item, username:, source:, since:) if counts[:old] == 1
            when :advert then @log.debug("#{source}/#{item.post_id}: advertises #{advert}, skipped")
            when :queued then yield item
            end
          end
        end

        @log.info("  #{counts[:rows]} rows, #{counts[:media]} media, " \
                  "#{counts[:queued]} queued#{tail_note(counts)}")
      end
    end

    private

    # Backpressure, not capacity. The producer is paced only by
    # requests_per_second and yields a page of items at a time, so an unbounded
    # queue would let it run to the end of every source while the pool trickles:
    # memory would scale with the library rather than with concurrency, and
    # `queued` would read as the whole timeline instead of what is waiting.
    QUEUE_DEPTH = 256
    private_constant :QUEUE_DEPTH

    def build_signer(rules) = Signer.new(rules:, user_id: jar.auth_id, xbc: jar.xbc)

    # What becomes of one item, and the one place the order of the tests is
    # written down: the counters and the panel both follow from the answer.
    #
    # `present?` runs here rather than in a worker: `queued` must count only
    # work that will be done, or a re-run passes its whole library through the
    # queue. The advert test runs after `present?`, so `ads` counts only media
    # the run would otherwise have fetched; an advert whose media is already on
    # disk counts as present instead.
    def verdict_for(item, username:, since:, seen:, advert:)
      return :old if since && item.posted_at < since
      return :duplicate unless seen.add?(item.key)
      return :present if present?(item, username)

      if advert
        @stats.bump(:ads)
        return :advert
      end

      @stats.bump(:queued)
      :queued
    end

    # `item` is the newest one older than `--since`. On disk means a previous
    # run downloaded it; absent means `--since` started later than the newest
    # gap in the library, so the posts between the two were never fetched and no
    # later run reaches them.
    #
    # Only this row is checked. A gap older than it goes unreported.
    def note_gap(item, username:, source:, since:)
      return unless username
      return if present?(item, username)

      @gaps << "#{username}/#{source}"
      @log.warn("  #{username}/#{source}: posts before #{since.strftime('%Y-%m-%d')} " \
                'are not on disk -- rerun with an earlier --since')
    end

    def count_discovery(item)
      @stats.bump(:media)
      @stats.bump(:images) if item.still?
      @stats.bump(:videos) if item.video?
    end

    # The stream is drained without a username in tests, where there is no
    # library to consult.
    def present?(item, username)
      username && library.have?(item, username:)
    end

    def tail_note(counts)
      ads = counts[:advert]
      parts = []
      parts << "#{counts[:present]} already on disk" if counts[:present].positive?
      parts << "#{ads} #{ads == 1 ? 'advert' : 'adverts'}" if ads.positive?
      dropped = counts[:old] + counts[:duplicate]
      parts << "#{dropped} duplicate or filtered out" if dropped.positive?
      parts.empty? ? '' : " (#{parts.join(', ')})"
    end

    # Closing the queue is what tells the consumers to finish, so it has to
    # happen even when a source raises mid-walk.
    # `seen` spans the run: a key reachable from two creators is the same post,
    # so the second sighting is a duplicate wherever it came from.
    #
    # creators_done counts creators scanned, not creators drained -- it moves
    # with the header's `scanning` field, which is the same producer position.
    def produce(queue, targets:, sources:, since:, skip_ads:)
      seen = Set.new

      in_walk_order(targets).each do |target|
        wait_for_count(target[:username])
        stream(user_id: target[:id], username: target[:username], sources:, since:, seen:, skip_ads:) do |item|
          queue << [item, target[:username]]
        end
        @stats.bump(:creators_done)
      end
    ensure
      queue.close
    end

    # A creator is listed only once the walk has passed it, so nothing is
    # downloaded into a directory the count has still to read.
    #
    # The field is set only when there is a real wait: seeing it means the run
    # is held up by the disk, and it is the producer that is waiting, not the
    # whole run -- the pool keeps draining whatever is already queued.
    def wait_for_count(username)
      name = library.walk_key(username)
      return if counted.passed?(name)

      @stats.scanning(creator: username, source: 'waiting for listing')
      counted.await(name)
    end

    # A download that raises anything other than DownloadError would otherwise
    # kill its worker silently, reducing the pool by one each time.
    def consume(item, username:, slot:)
      downloader.call(item, username:, slot:)
    rescue StandardError => e
      Outcome.new(item:, status: :failed, bytes: 0, message: "#{e.class}: #{e.message}")
    end

    def each_row(source, user_id, since: nil, &)
      enumerator =
        case source
        when 'posts' then api.posts(user_id, since:)
        when 'archived' then api.posts(user_id, archived: true, since:)
        when 'messages' then api.messages(user_id, since:)
        when 'paid' then api.paid(user_id, since:)
        when 'stories' then api.stories(user_id)
        when 'highlights' then api.highlights(user_id)
        else raise ConfigError, "unknown source #{source.inspect}"
        end

      enumerator.each(&)
    rescue ApiError => e
      @log.warn("#{source}: #{e.message} -- continuing without it")
    end

    # There is no total to count towards -- enumeration is still running while
    # these land.
    # Each line names its creator, because the pool interleaves them: the run is
    # no longer one creator at a time. The path shown is the library layout,
    # <creator>/<source>/<file>.
    def report(outcome, tally, username)
      creator = Palette.blue(username)

      case outcome.status
      when :downloaded
        @log.info("  ✓ #{creator}/#{outcome.item.source}/#{outcome.item.filename}  #{Display.humanize(outcome.bytes)}")
      when :protected
        @log.info("  ~ #{creator}/#{outcome.item.source}/#{outcome.item.key}  DRM, skipped")
      when :failed
        @log.error("  ✗ #{creator}/#{outcome.item.filename} -- #{outcome.message}")
      else
        @log.progress("#{creator}  #{tally[:done]} processed, #{Display.humanize(tally[:bytes])} fetched")
      end
    end
  end
end
