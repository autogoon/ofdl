# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'

module OFDL
  class SummaryTest < TestCase
    def outcome(status, bytes = 0)
      Outcome.new(item: nil, status:, bytes:, message: nil)
    end

    def test_accumulates_by_status
      summary = [outcome(:downloaded, 10), outcome(:skipped), outcome(:protected), outcome(:failed)]
                .reduce(Summary.empty) { |acc, o| acc.add(o) }

      assert_equal(1, summary.downloaded)
      assert_equal(1, summary.skipped)
      assert_equal(1, summary.protected)
      assert_equal(1, summary.failed)
      assert_equal(10, summary.bytes)
      assert_equal(4, summary.total)
    end

    def test_merges
      a = Summary.empty.add(outcome(:downloaded, 5))
      b = Summary.empty.add(outcome(:downloaded, 7))

      assert_equal(12, a.merge(b).bytes)
      assert_equal(2, a.merge(b).downloaded)
    end
  end

  class SessionCollectTest < TestCase
    FakeApi = Struct.new(:by_source) do
      def posts(_id, archived: false) = by_source.fetch(archived ? 'archived' : 'posts', [])
      def messages(_id) = by_source.fetch('messages', [])
      def stories(_id) = by_source.fetch('stories', [])
      def paid(_id) = by_source.fetch('paid', [])
      def highlights(_id) = by_source.fetch('highlights', [])
    end

    def row(post_id, media_id, posted_at)
      {
        'id' => post_id,
        'postedAt' => posted_at,
        'media' => [{
          'id' => media_id, 'type' => 'photo',
          'files' => { 'full' => { 'url' => "https://cdn.example.com/#{media_id}.jpg" } }
        }]
      }
    end

    # Session#stream yields items rather than returning them; collect them into
    # an array to assert on.
    def collect_from(session, **)
      items = []
      session.stream(**) { items << it }
      items
    end

    # Blocks until the producer is held at the watermark rather than sleeping a
    # fixed time, so the test is not paced by the machine it runs on.
    def await_wait(session)
      Timeout.timeout(5) { sleep(0.001) until session.stats.source == 'waiting for listing' }
    end

    # The real Library over a root that does not exist: nothing is present and
    # there is nothing to walk, so every method the producer calls is the real
    # one and a change to Library is felt here rather than duplicated.
    class FakeLibrary < Library
      def initialize
        super(root: Pathname('/nonexistent'), log: Logging.new(io: StringIO.new, level: :error, colour: false))
      end
    end

    class SignallingDownloader
      def initialize(signal) = @signal = signal

      def call(item, username:, slot: 0)
        Outcome.new(item:, status: :downloaded, bytes: 1, message: nil).tap { @signal << :done }
      end
    end

    def streaming_session(api, signal)
      config = Config.new(Pathname(Dir.mktmpdir).join('ofdl-config.json'))
      session = Session.new(config:, log: silent_log)
      session.instance_variable_set(:@api, api)
      session.instance_variable_set(:@downloader, SignallingDownloader.new(signal))
      session.instance_variable_set(:@library, FakeLibrary.new)
      session
    end

    def session_with(by_source)
      config = Config.new(Pathname(Dir.mktmpdir).join('ofdl.config.json'))
      session = Session.new(config:, log: silent_log)
      session.instance_variable_set(:@api, FakeApi.new(by_source))
      session
    end

    def test_deduplicates_across_sources
      shared = row(1, 10, '2026-01-14T00:00:00Z')
      session = session_with({ 'posts' => [shared], 'paid' => [shared] })

      items = collect_from(session, user_id: 1, sources: %w[posts paid])

      assert_equal(1, items.size)
      assert_equal('1_10', items.first.key)
    end

    def test_since_filters_by_post_date
      session = session_with({ 'posts' => [
                               row(1, 10, '2026-01-01T00:00:00Z'),
                               row(2, 20, '2026-06-01T00:00:00Z')
                             ] })

      items = collect_from(session, user_id: 1, sources: %w[posts], since: Time.utc(2026, 3, 1))

      assert_equal([20], items.map(&:media_id))
    end

    # The fake enumerator withholds its second row until a download has
    # completed, so an archive that enumerated everything before downloading
    # would deadlock and fail on the timeout.
    def test_downloading_starts_before_enumeration_finishes
      downloaded = Queue.new
      blocking = Object.new
      blocking.define_singleton_method(:posts) do |_id, archived: false|
        rows = [
          { 'id' => 1, 'postedAt' => '2026-01-14T00:00:00Z',
            'media' => [{ 'id' => 10, 'type' => 'photo',
                          'files' => { 'full' => { 'url' => 'https://cdn.example.com/10.jpg' } } }] },
          { 'id' => 2, 'postedAt' => '2026-01-14T00:00:00Z',
            'media' => [{ 'id' => 20, 'type' => 'photo',
                          'files' => { 'full' => { 'url' => 'https://cdn.example.com/20.jpg' } } }] }
        ]
        Enumerator.new do |y|
          y << rows[0]
          downloaded.pop # blocks until something has actually been fetched
          y << rows[1]
        end
      end

      session = streaming_session(blocking, downloaded)

      Timeout.timeout(5) do
        summary = session.archive(targets: [{ id: 1, username: 'creator' }], sources: %w[posts])

        assert_equal(2, summary.downloaded)
      end
    end

    # `queued` is a gauge, not a tally -- see Stats::COUNTERS.
    def test_queued_returns_to_nothing_when_the_run_drains
      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z'),
                                           row(2, 20, '2026-01-14T00:00:00Z')] })
      quiet = Object.new
      quiet.define_singleton_method(:call) do |item, username:, slot: 0|
        Outcome.new(item:, status: :downloaded, bytes: 1, message: nil)
      end
      session.instance_variable_set(:@downloader, quiet)
      session.instance_variable_set(:@library, FakeLibrary.new)

      Timeout.timeout(5) { session.archive(targets: [{ id: 1, username: 'creator' }], sources: %w[posts]) }

      assert_equal(0, session.stats.queued)
    end

    # See Stats#done_scanning.
    def test_scanning_reads_done_once_every_source_is_walked
      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z')] })
      quiet = Object.new
      quiet.define_singleton_method(:call) do |item, username:, slot: 0|
        Outcome.new(item:, status: :downloaded, bytes: 1, message: nil)
      end
      session.instance_variable_set(:@downloader, quiet)
      session.instance_variable_set(:@library, FakeLibrary.new)

      Timeout.timeout(5) { session.archive(targets: [{ id: 1, username: 'creator' }], sources: %w[posts]) }

      assert_equal('done', session.stats.source)
    end

    # A pool per creator could not begin the second creator's enumeration until
    # the first creator's downloads had drained. The first download blocks until
    # the producer reaches the second creator, so an archive that drains per
    # creator deadlocks and fails on the timeout.
    def test_discovery_reaches_the_next_creator_before_the_first_drains
      reached_second = Queue.new
      api = Object.new
      api.define_singleton_method(:posts) do |id, archived: false|
        reached_second << :reached if id == 2
        [{ 'id' => id, 'postedAt' => '2026-01-14T00:00:00Z',
           'media' => [{ 'id' => id * 10, 'type' => 'photo',
                         'files' => { 'full' => { 'url' => "https://cdn.example.com/#{id}.jpg" } } }] }]
      end
      %i[messages stories paid highlights].each { |name| api.define_singleton_method(name) { |_id| [] } }

      fetched = Queue.new
      blocking = Object.new
      blocking.define_singleton_method(:call) do |item, username:, slot: 0|
        reached_second.pop if username == 'alice'
        fetched << username
        Outcome.new(item:, status: :downloaded, bytes: 1, message: nil)
      end

      session = session_with({})
      session.instance_variable_set(:@api, api)
      session.instance_variable_set(:@downloader, blocking)
      session.instance_variable_set(:@library, FakeLibrary.new)

      summary = Timeout.timeout(5) do
        session.archive(targets: [{ id: 1, username: 'alice' }, { id: 2, username: 'bob' }],
                        sources: %w[posts])
      end

      assert_equal(2, summary.downloaded)
      # The username travelled with its item rather than being closed over.
      assert_equal(%w[alice bob], Array.new(2) { fetched.pop }.sort)
    end

    def test_a_download_that_raises_is_recorded_not_fatal
      exploding = Object.new
      exploding.define_singleton_method(:call) { |_item, username:, slot: 0| raise('boom') }

      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z')] })
      session.instance_variable_set(:@downloader, exploding)
      session.instance_variable_set(:@library, FakeLibrary.new)

      summary = Timeout.timeout(5) { session.archive(targets: [{ id: 1, username: 'creator' }], sources: %w[posts]) }

      assert_equal(1, summary.failed)
    end

    # `queued` counts only work that will be done, so the producer drops items
    # already on disk rather than yielding them -- see Session#stream.
    #
    # Nothing consumes the stream here, so the gauge stays at what was pushed.
    def test_items_already_on_disk_are_not_queued
      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z'),
                                           row(2, 20, '2026-01-14T00:00:00Z')] })
      have = Object.new
      have.define_singleton_method(:have?) { |item, username:| item.media_id == 10 }
      session.instance_variable_set(:@library, have)

      items = collect_from(session, user_id: 1, sources: %w[posts], username: 'creator')

      assert_equal([20], items.map(&:media_id))
      assert_equal(1, session.stats.queued)
    end

    # `on disk` comes from the tree, not from what the run lists; see
    # Session#count_library.
    def test_the_library_is_counted_without_reference_to_the_run
      session = session_with({})
      library = FakeLibrary.new
      library.define_singleton_method(:tally) do |on_creator: nil, &progress|
        # Per file rather than per directory, so the panel fills in as it walks.
        3.times { progress.call(1, 2048) }
        on_creator.call('alice')
        [3, 6144]
      end
      session.instance_variable_set(:@library, library)

      Timeout.timeout(5) { session.count_library.join }

      assert_equal(3, session.stats.on_disk)
      assert_equal(6144, session.stats.on_disk_bytes)
      assert(session.counted.passed?('alice'))
    end

    # The walk runs alongside the listing, so a creator is held back until the
    # walk has passed it -- no worker writes into a directory still to be read.
    def test_a_creator_is_not_listed_until_the_walk_has_passed_it
      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z')] })
      session.instance_variable_set(:@library, FakeLibrary.new)
      session.instance_variable_set(:@downloader, SignallingDownloader.new(Queue.new))
      gate = Watermark.new
      session.instance_variable_set(:@counted, gate)

      run = Thread.new { session.archive(targets: [{ id: 1, username: 'creator' }], sources: %w[posts]) }
      await_wait(session)

      assert_equal('creator', session.stats.creator)
      assert_equal(0, session.stats.media)

      gate.pass('creator')

      assert_equal(1, Timeout.timeout(5) { run.value }.downloaded)
    end

    # Both sides order by the directory name, or the producer waits on a
    # creator the walk has already gone past; see Session#in_walk_order.
    def test_creators_are_taken_in_the_order_the_walk_uses
      session = session_with({ 'posts' => [] })
      session.instance_variable_set(:@library, FakeLibrary.new)
      gate = Watermark.new
      session.instance_variable_set(:@counted, gate)

      run = Thread.new do
        session.archive(targets: [{ id: 2, username: 'bob' }, { id: 1, username: 'alice' }], sources: %w[posts])
      end
      await_wait(session)

      assert_equal('alice', session.stats.creator)
    ensure
      gate.finish
      Timeout.timeout(5) { run&.join }
    end

    # Split by OnlyFans' classification, not by the extension -- see Item#still?.
    def test_discovered_media_is_split_into_stills_and_video
      rows = [row(1, 10, '2026-01-14T00:00:00Z'), row(2, 20, '2026-01-14T00:00:00Z')]
      rows[1]['media'][0]['type'] = 'video'
      session = session_with({ 'posts' => rows })

      collect_from(session, user_id: 1, sources: %w[posts])

      assert_equal(1, session.stats.images)
      assert_equal(1, session.stats.videos)
    end

    def test_tags_items_with_their_source
      session = session_with({ 'posts' => [row(1, 10, '2026-01-14T00:00:00Z')],
                               'messages' => [row(2, 20, '2026-01-14T00:00:00Z')] })

      items = collect_from(session, user_id: 1, sources: %w[posts messages])

      assert_equal(%w[posts messages], items.map(&:source))
    end
  end
end
