# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'tmpdir'

module OFDL
  # Covers Display#image.
  class ImagePreviewTest < TestCase
    class FakeTTY < StringIO
      def initialize(rows: 40, columns: 100)
        super()
        @size = [rows, columns]
      end

      def tty? = true

      def winsize = @size
    end

    def setup
      @dir = Dir.mktmpdir('ofdl-image')
      @io = FakeTTY.new
      @display = Display.new(io: @io, header_lines: 6, log_lines: 8, footer_lines: 6)
      @display.start
      @io.truncate(0)
      @io.rewind
    end

    def teardown = FileUtils.remove_entry(@dir)

    def jpeg(bytes: 1000)
      path = File.join(@dir, 'photo.jpg')
      File.binwrite(path, "\xFF\xD8\xFF\xE0".b + ('x'.b * bytes))
      path
    end

    def output = @io.string

    def test_emits_the_iterm2_inline_image_sequence
      @display.image(jpeg)

      assert_includes(output, "\e]1337;File=")
      assert_includes(output, 'inline=1')
      assert_includes(output, "\a")
    end

    # Width and height in cells, not the file's own pixels; see Display#image.
    def test_constrains_the_image_to_the_zone
      @display.image(jpeg)

      assert_includes(output, "height=#{@display.image_lines}")
      assert_includes(output, 'width=100')
    end

    # Why aspect correction is off: see Display#inline_image.
    def test_the_image_fills_the_slice
      @display.image(jpeg)

      assert_includes(output, 'preserveAspectRatio=0')
    end

    def test_sends_the_file_verbatim_as_base64
      path = jpeg
      @display.image(path)

      assert_includes(output, [File.binread(path)].pack('m0'))
    end

    def test_draws_below_the_header
      @display.image(jpeg)

      assert_includes(output, "\e[7;1H")
    end

    # Spaces over the slice's own columns, not "\e[K" to end of line; see
    # Display#clear_slice.
    def test_clears_its_own_columns_before_drawing
      @display.image(jpeg)

      assert_includes(output, "\e[7;1H#{' ' * 100}")
    end

    def test_a_slice_only_blanks_its_own_columns
      @display.image(jpeg, slot: 1, slots: 4)

      assert_includes(output, "\e[7;26H#{' ' * 25}")
      refute_includes(output, "\e[7;1H#{' ' * 25}")
    end

    def test_the_whole_redraw_is_one_synchronized_update
      @display.image(jpeg)

      assert(output.start_with?(Display::BEGIN_SYNC), 'redraw did not open a synchronized update')
      assert(output.end_with?(Display::END_SYNC), 'redraw did not close a synchronized update')
    end

    def test_draws_into_the_slice_belonging_to_the_slot
      @display.image(jpeg, slot: 2, slots: 4)

      assert_includes(output, "\e[7;51H\e]1337;File=")
      assert_includes(output, 'width=25')
    end

    def test_the_first_slot_starts_at_the_left_edge
      @display.image(jpeg, slot: 0, slots: 4)

      assert_includes(output, "\e[7;1H\e]1337;File=")
    end

    # Why there is a cap: see Display::MAX_IMAGE_BYTES.
    def test_skips_an_image_beyond_the_size_cap
      path = File.join(@dir, 'huge.png')
      File.binwrite(path, 'x'.b * (Display::MAX_IMAGE_BYTES + 1))
      @display.image(path)

      assert_empty(output)
    end

    def test_a_missing_file_is_survivable
      @display.image(File.join(@dir, 'absent.jpg'))

      assert_empty(output)
    end

    def test_an_empty_file_draws_nothing
      path = File.join(@dir, 'empty.jpg')
      File.binwrite(path, '')
      @display.image(path)

      assert_empty(output)
    end

    # 14 rows: the header, log and footer allowances leave no image zone.
    def test_nothing_is_drawn_when_there_is_no_zone
      io = FakeTTY.new(rows: 14)
      display = Display.new(io:, header_lines: 6, log_lines: 8, footer_lines: 6)
      display.start
      io.truncate(0)
      io.rewind
      display.image(jpeg)

      assert_empty(io.string)
    end

    def test_only_images_are_previewed
      photo = Item.new(media_id: 1, post_id: 2, source: 'posts', kind: 'photo',
                       posted_at: Time.now, url: 'u', protected: false, extension: 'jpg')
      video = photo.with(extension: 'mp4')

      assert_predicate(photo, :image?)
      refute_predicate(video, :image?)
    end
  end
end
