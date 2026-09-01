# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class DownloaderTest < TestCase
    # Writes the file curl would have written, and reports the status given.
    class FakeTransport
      attr_reader :requests

      def initialize(status: 200, bytes: 1234)
        @status = status
        @bytes = bytes
        @requests = []
      end

      def download(url, destination, dump_headers: nil)
        @requests << url
        File.binwrite(destination, 'x' * @bytes)
        File.write(dump_headers, "HTTP/2 200\r\ncontent-length: #{@bytes}\r\n\r\n") if dump_headers
        @status
      end
    end

    class RecordingPreview
      attr_reader :shown

      def initialize = @shown = []

      def show(slot, path) = @shown << [slot, Pathname(path)]
    end

    # Lets a test observe the moment publishing begins, and interleave another
    # download with it.
    class ObservingScratch < Scratch
      attr_reader :published
      attr_accessor :during_publish, :observe

      def initialize(**rest)
        super
        @published = []
      end

      def publish(working, destination)
        @observe&.call
        @published << destination
        if (hook = @during_publish)
          @during_publish = nil
          hook.call
        end
        super
      end
    end

    def setup
      @dir = Pathname(Dir.mktmpdir('ofdl-downloader'))
      @out = @dir.join('out').tap(&:mkpath)
      @stats = Stats.new
      @preview = RecordingPreview.new
      @scratch = ObservingScratch.new(root: @dir.join('work').tap(&:mkpath))
      @library = Library.new(root: @out, log: silent_log)
      @config = Config.new(@dir.join('config.json'))
    end

    def teardown = FileUtils.remove_entry(@dir)

    def item(extension: 'jpg', key: '111_222')
      post, media = key.split('_')
      Item.new(media_id: media, post_id: post, post_type: 'posts', kind: 'photo',
               posted_at: Time.utc(2026, 1, 14), url: "https://cdn.example.com/a.#{extension}",
               protected: false, extension:)
    end

    def downloader(transport: FakeTransport.new)
      Downloader.new(library: @library, config: @config, log: silent_log,
                     transport:, scratch: @scratch, stats: @stats, preview: @preview)
    end

    def test_a_download_lands_in_the_output_directory
      outcome = downloader.call(item, username: 'creator')

      assert_equal(:downloaded, outcome.status)
      assert_equal(1234, outcome.bytes)
      assert_path_exists(@out.join('creator', 'posts', '2026-01-14_111_222.jpg'))
    end

    # See Scratch#publish for why nothing partial may appear under the final name.
    def test_the_staging_file_does_not_survive
      downloader.call(item, username: 'creator')

      assert_empty(Pathname.glob(@out.join('**', '*.part')))
    end

    # See Downloader#fetch for why the preview is drawn before the copy.
    def test_the_image_is_drawn_before_the_copy_begins
      drawn_at_publish = nil
      @scratch.observe = -> { drawn_at_publish = @preview.shown.size }

      downloader.call(item, username: 'creator')

      assert_equal(1, drawn_at_publish, 'the image was drawn after publishing, not before')
    end

    def test_the_image_is_drawn_into_the_workers_own_slot
      downloader.call(item, username: 'creator', slot: 2)

      assert_equal([2], @preview.shown.map(&:first))
    end

    def test_the_image_drawn_is_the_local_scratch_file
      subject = item
      downloader.call(subject, username: 'creator')

      assert_equal(@scratch.path_for(subject), @preview.shown.first.last)
    end

    def test_the_scratch_file_is_cleaned_up_afterwards
      subject = item
      downloader.call(subject, username: 'creator')

      refute_path_exists(@scratch.path_for(subject))
      refute_path_exists(@scratch.headers_for(subject))
    end

    def test_a_video_is_not_drawn
      downloader.call(item(extension: 'mp4', key: '111_333'), username: 'creator')

      assert_empty(@preview.shown)
    end

    # See Stats#phase.
    def test_the_slot_reports_what_it_is_doing_after_the_bytes_arrive
      seen = []
      @scratch.observe = -> { seen << @stats.active[0][:phase] }

      downloader.call(item, username: 'creator')

      assert_equal([:moving], seen)
    end

    def test_an_image_reports_rendering_before_it_reports_moving
      seen = []
      @preview.define_singleton_method(:show) { |_slot, _path| seen << :shown }
      @scratch.observe = -> { seen << @stats.active[0][:phase] }

      downloader.call(item, username: 'creator')

      assert_equal(%i[shown moving], seen)
    end

    # Each worker owns the scratch file it publishes, so another worker
    # finishing mid-publish cannot remove the file this one is copying.
    def test_another_download_completing_mid_publish_is_harmless
      subject = downloader
      @scratch.during_publish = -> { subject.call(item(key: '111_444'), username: 'creator', slot: 1) }

      outcome = subject.call(item(key: '111_222'), username: 'creator', slot: 0)

      assert_equal(:downloaded, outcome.status, outcome.message)
      assert_path_exists(@out.join('creator', 'posts', '2026-01-14_111_222.jpg'))
      assert_path_exists(@out.join('creator', 'posts', '2026-01-14_111_444.jpg'))
    end

    def test_a_failed_download_leaves_nothing_behind
      outcome = downloader(transport: FakeTransport.new(status: 404)).call(item, username: 'creator')

      assert_equal(:failed, outcome.status)
      refute_path_exists(@scratch.path_for(item))
      assert_empty(Pathname.glob(@out.join('**', '*')).select(&:file?))
    end

    def test_the_slot_is_released_when_the_download_ends
      downloader.call(item, username: 'creator', slot: 3)

      assert_empty(@stats.active)
    end

    def test_an_item_already_on_disk_is_skipped_without_a_request
      transport = FakeTransport.new
      subject = downloader(transport:)
      subject.call(item, username: 'creator')
      subject.call(item, username: 'creator')

      assert_equal(1, transport.requests.size)
    end
  end
end
