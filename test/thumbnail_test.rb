# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'open3'

module OFDL
  # The geometry and the nil returns are documented at Thumbnail.build.
  class ThumbnailTest < TestCase
    def setup
      @dir = Pathname(Dir.mktmpdir('ofdl-thumb'))
      @original = @dir.join('original.jpg')
    end

    def teardown = FileUtils.remove_entry(@dir)

    # A 1x1 PNG resampled by sips to the shape asked for, so no fixture image
    # is committed.
    def shaped(width, height)
      png = @dir.join('seed.png')
      png.binwrite(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
          .unpack1('m')
      )
      system('sips', '-s', 'format', 'jpeg', '-z', height.to_s, width.to_s,
             png.to_s, '--out', @original.to_s, out: File::NULL, err: File::NULL)
      @original
    end

    def dimensions(path)
      out, = Open3.capture2e('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path.to_s)
      out.scan(/pixel(?:Width|Height):\s*(\d+)/).flatten.map(&:to_i)
    end

    # Cover, not contain: the overflow is cropped, so the output is the box.
    def test_a_landscape_image_covers_the_box_exactly
      skip('sips unavailable') unless Thumbnail.available?

      shaped(1600, 1200)
      target = @dir.join('thumb.jpg')

      assert_equal(target, Thumbnail.build(@original, target, width: 800, height: 600))
      assert_equal([800, 600], dimensions(target))
    end

    def test_a_portrait_image_covers_the_box_exactly
      skip('sips unavailable') unless Thumbnail.available?

      shaped(1200, 1600)

      Thumbnail.build(@original, @dir.join('thumb.jpg'), width: 800, height: 600)

      assert_equal([800, 600], dimensions(@dir.join('thumb.jpg')))
    end

    # 6:1 into a square box: scaling on the wrong axis gives 300x50, which the
    # crop pads rather than fills.
    def test_a_wildly_wrong_shape_still_covers
      skip('sips unavailable') unless Thumbnail.available?

      shaped(2400, 400)

      Thumbnail.build(@original, @dir.join('thumb.jpg'), width: 300, height: 300)

      assert_equal([300, 300], dimensions(@dir.join('thumb.jpg')))
    end

    def test_the_thumbnail_is_dramatically_smaller
      skip('sips unavailable') unless Thumbnail.available?

      shaped(2000, 2000)
      target = @dir.join('thumb.jpg')
      Thumbnail.build(@original, target, width: 400, height: 300)

      assert_operator(target.size, :<, @original.size / 4,
                      'thumbnail is not small enough to fix the flash')
    end

    def test_a_missing_source_returns_nil
      assert_nil(Thumbnail.build(@dir.join('absent.jpg'), @dir.join('out.jpg'), width: 400, height: 300))
    end

    def test_a_missing_binary_returns_nil
      skip('sips unavailable') unless Thumbnail.available?

      shaped(200, 200)

      assert_nil(Thumbnail.build(@original, @dir.join('out.jpg'), width: 400, height: 300, binary: 'sips-not-here'))
    end

    def test_a_nonsense_size_returns_nil
      assert_nil(Thumbnail.build(@original, @dir.join('out.jpg'), width: 0, height: 300))
    end

    def test_availability_is_detectable
      refute(Thumbnail.available?(binary: 'sips-not-here'))
    end
  end
end
