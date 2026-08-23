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

    def initialize(config:, log:, stats: Stats.new, preview: nil)
      @config = config
      @log = log
      @stats = stats
      @preview = preview
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
    def archive(targets:, sources: @config.sources, since: nil)
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

      produce(queue, targets:, sources:, since:)
      @stats.done_scanning
      consumers.each(&:join)
      @log.clear_progress
      summary
    end

    # Yields each item the moment it is found. Deduplicated across sources: the
    # same media often appears in both a timeline and the paid feed.
    def stream(user_id:, sources:, since: nil, username: nil, seen: Set.new)
      sources.each do |source|
        @log.step("#{"#{username} " if username}#{source}")
        @stats.scanning(creator: username, source:)
        rows = media = queued = present = 0

        each_row(source, user_id) do |row|
          rows += 1
          Media.from_row(row, source:).each do |item|
            media += 1
            @stats.bump(:media)
            @stats.bump(:images) if item.still?
            @stats.bump(:videos) if item.video?
            next if since && item.posted_at < since
            next unless seen.add?(item.key)

            # Decided here rather than in a worker: the producer already knows
            # what is on disk, and `queued` must count only work that will be
            # done, or a re-run passes its whole library through the queue.
            if present?(item, username)
              present += 1
              # The only chance to size it: a skipped item is never downloaded.
              # One stat of a file nobody is writing, on the producer thread.
              @stats.bump(:on_disk).bump(:on_disk_bytes, library.size_of(item, username:))
              next
            end

            queued += 1
            @stats.bump(:queued)
            yield item
          end
        end

        @log.info("  #{rows} rows, #{media} media, #{queued} queued" \
                  "#{tail_note(media, queued, present)}")
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

    # The stream is drained without a username in tests, where there is no
    # library to consult.
    def present?(item, username)
      username && library.have?(item, username:)
    end

    def tail_note(media, queued, present)
      dropped = media - queued - present
      parts = []
      parts << "#{present} already on disk" if present.positive?
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
    def produce(queue, targets:, sources:, since:)
      seen = Set.new

      targets.each do |target|
        stream(user_id: target[:id], username: target[:username], sources:, since:, seen:) do |item|
          queue << [item, target[:username]]
        end
        @stats.bump(:creators_done)
      end
    ensure
      queue.close
    end

    # A download that raises anything other than DownloadError would otherwise
    # kill its worker silently, reducing the pool by one each time.
    def consume(item, username:, slot:)
      downloader.call(item, username:, slot:)
    rescue StandardError => e
      Outcome.new(item:, status: :failed, bytes: 0, message: "#{e.class}: #{e.message}")
    end

    def each_row(source, user_id, &)
      enumerator =
        case source
        when 'posts' then api.posts(user_id)
        when 'archived' then api.posts(user_id, archived: true)
        when 'messages' then api.messages(user_id)
        when 'paid' then api.paid(user_id)
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
