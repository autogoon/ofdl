# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class LibraryTest < TestCase
    def setup
      @dir = Dir.mktmpdir('ofdl-test')
      @library = Library.new(root: @dir, log: silent_log)
    end

    def teardown = FileUtils.remove_entry(@dir)

    def item(media_id: 222, extension: 'jpg', protected: false)
      Item.new(
        media_id:, post_id: 111, source: 'posts', kind: 'photo',
        posted_at: Time.utc(2026, 1, 14), url: 'https://cdn.example.com/a.jpg',
        protected:, extension:
      )
    end

    def test_resumption_reads_the_filesystem
      subject = item
      refute(@library.have?(subject, username: 'creator'))

      path = @library.prepare(subject, username: 'creator')
      path.write('bytes')

      fresh = Library.new(root: @dir, log: silent_log)
      assert(fresh.have?(subject, username: 'creator'))
    end

    # A marker written by one run is read back by the next as present, so the
    # item is not queued; see Library's `.drm` marker.
    def test_markers_count_as_present
      subject = item(media_id: 333, extension: 'mpd', protected: true)
      @library.write_marker(subject, username: 'creator')

      fresh = Library.new(root: @dir, log: silent_log)
      assert(fresh.have?(subject, username: 'creator'))
      assert_path_exists(File.join(@dir, 'creator', 'posts', '2026-01-14_111_333.mpd.drm'))
    end

    def test_partials_do_not_count_as_present
      subject = item
      path = @library.prepare(subject, username: 'creator')
      Pathname("#{path}.part").write('half')

      fresh = Library.new(root: @dir, log: silent_log)
      refute(fresh.have?(subject, username: 'creator'))
    end

    def test_sweep_removes_stale_partials
      path = @library.prepare(item, username: 'creator')
      Pathname("#{path}.part").write('half')

      assert_equal(1, @library.sweep_partials!)
      refute_path_exists("#{path}.part")
    end

    def test_usernames_with_separators_cannot_escape_the_root
      subject = item
      path = @library.path_for(subject, username: '../../etc')

      assert_equal(File.join(@dir, '.._.._etc', 'posts', '2026-01-14_111_222.jpg'), path.to_s)
    end

    def test_ensure_root_accepts_an_existing_writable_directory
      assert_equal(Pathname(@dir), @library.ensure_root!)
    end

    # See Library#ensure_root! for why an absent root is not created.
    def test_ensure_root_refuses_to_create_a_missing_root
      missing = File.join(@dir, 'gone')
      library = Library.new(root: missing, log: silent_log)

      error = assert_raises(ConfigError) { library.ensure_root! }

      assert_match(/will not be created/, error.message)
      assert_match(/network volume/, error.message)
      refute_path_exists(missing)
    end

    def test_ensure_root_names_the_nearest_existing_path
      library = Library.new(root: File.join(@dir, 'a', 'b', 'c'), log: silent_log)

      error = assert_raises(ConfigError) { library.ensure_root! }

      assert_match(/nearest existing path: #{Regexp.escape(@dir)}\b/, error.message)
    end

    def test_ensure_root_rejects_a_file
      file = File.join(@dir, 'not-a-dir')
      File.write(file, 'x')
      library = Library.new(root: file, log: silent_log)

      assert_match(/not a directory/, assert_raises(ConfigError) { library.ensure_root! }.message)
    end

    def test_prepare_does_not_create_a_missing_root
      missing = File.join(@dir, 'gone')
      library = Library.new(root: missing, log: silent_log)

      assert_raises(ConfigError) { library.prepare(item, username: 'creator') }
      refute_path_exists(missing)
    end

    def test_write_marker_does_not_create_a_missing_root
      missing = File.join(@dir, 'gone')
      library = Library.new(root: missing, log: silent_log)

      assert_raises(ConfigError) do
        library.write_marker(item(media_id: 333, extension: 'mpd', protected: true), username: 'creator')
      end
      refute_path_exists(missing)
    end

    def test_counts_separate_files_from_markers
      @library.prepare(item, username: 'creator').write('12345')
      @library.write_marker(item(media_id: 333, extension: 'mpd', protected: true), username: 'creator')

      counts = @library.counts

      assert_equal(1, counts[:files])
      assert_equal(1, counts[:protected])
      assert_equal(5, counts[:bytes])
    end
  end
end
