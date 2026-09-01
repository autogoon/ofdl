# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class StatusReportTest < TestCase
    # Collects the lines the report writes, so a test reads what `ofdl status`
    # would print.
    class RecordingLog
      attr_reader :lines

      def initialize = @lines = []

      def step(text) = @lines << text
      def info(text) = @lines << text
      def warn(text) = @lines << text
      def debug(text = nil) = @lines << text
    end

    def setup
      @dir = Pathname(Dir.mktmpdir('ofdl-status'))
      @log = RecordingLog.new
      @config = Config.new(@dir.join('config.json'))
      @config.data['output_dir'] = @dir.join('library').tap(&:mkpath).to_s
    end

    def teardown = FileUtils.remove_entry(@dir)

    def report(session: nil) = StatusReport.new(config: @config, log: @log, session:)

    def library_session
      session = Object.new
      library = Library.new(root: @config.output_dir, log: silent_log)
      session.define_singleton_method(:library) { library }
      session
    end

    def printed = @log.lines.join("\n")

    # Off by default because Library#counts stats every file under output_dir,
    # which on a mounted share is one network round trip each.
    def test_the_library_is_not_counted_until_it_is_asked_for
      report(session: library_session).library(stats: false)

      assert_match(/--library-stats/, printed)
      refute_match(/files/, printed)
    end

    def test_asking_for_stats_counts_the_tree
      item = Item.new(media_id: 222, post_id: 111, source: Source::ONLYFANS, post_type: 'posts', kind: 'photo',
                      posted_at: Time.utc(2026, 1, 14), url: 'https://cdn.example.com/a.jpg',
                      protected: false, extension: 'jpg')
      session = library_session
      session.library.prepare(item, username: 'creator').write('12345')

      report(session:).library(stats: true)

      assert_match(/creators\s+1/, printed)
      assert_match(/files\s+1/, printed)
    end

    # <output_dir>/<source>/<creator>/, so a source directory on its own is not
    # a creator; see Library.
    def test_creators_are_counted_below_the_app_not_at_the_top
      @config.output_dir.join('onlyfans', 'alice').mkpath
      @config.output_dir.join('onlyfans', 'bob').mkpath

      report(session: library_session).library(stats: true)

      assert_match(/creators\s+2/, printed)
    end

    # The message names what to do about it, so a missing mount is not read as
    # a typo; see Library#ensure_root!.
    def test_an_unusable_output_dir_is_reported_rather_than_raised
      @config.data['output_dir'] = @dir.join('gone').to_s

      report(session: library_session).library(stats: true)

      assert_match(/will not be created/, printed)
    end

    def test_bytes_are_printed_in_units
      subject = report
      assert_equal('512 B', subject.send(:human_bytes, 512))
      assert_equal('1.0 KB', subject.send(:human_bytes, 1024))
      assert_equal('1.5 MB', subject.send(:human_bytes, 1024 * 1536))
    end

    # Session material is printed as a prefix only: enough to compare against
    # the browser, not enough to reuse.
    def test_long_values_are_truncated
      subject = report

      assert_equal("#{'x' * 24}...", subject.send(:truncate, 'x' * 40))
      assert_equal('short', subject.send(:truncate, 'short'))
    end
  end
end
