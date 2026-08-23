# frozen_string_literal: true

require 'open3'

module OFDL
  # Shrinks an image to roughly the size it will be displayed at, using sips.
  #
  # Resizing keeps the preview from flashing: drawing blanks the slice and then
  # fills it, and the terminal paints that as one frame only if the whole
  # sequence arrives inside its synchronized-output window. A multi-megabyte JPEG
  # does not; a photo scaled to the slice is around 20 KB and does.
  #
  # sips over an image library because it ships with macOS: no native build, no
  # ImageMagick. It costs about 70ms, on a worker thread that is about to spend
  # considerably longer copying the original to the output directory.
  module Thumbnail
    BINARY = 'sips'

    # sips accepts low/normal/high/best or a percentage. Below `normal` the file
    # stops shrinking much and starts looking worse.
    QUALITY = 'normal'

    class << self
      # Scales an image to cover a box and crops the overflow, so the result is
      # exactly `width` x `height`.
      #
      # A picture wider in aspect than the box is scaled to the box's height and
      # cropped horizontally, a narrower one the other way round. Scaling on the
      # wrong axis leaves a gap.
      #
      # Returns the thumbnail's path, or nil if it could not be made. The caller
      # must then draw nothing: the original is not cropped to the slice, so it
      # would letterbox or stretch.
      def build(source, target, width:, height:, binary: BINARY)
        return nil unless width.positive? && height.positive?

        source_width, source_height = dimensions(source, binary:)
        return nil unless source_width&.positive? && source_height&.positive?

        _, status = Open3.capture2e(
          binary, *scale_to_cover(source_width, source_height, width, height),
          # -c takes height before width, unlike everything else here.
          '-c', height.to_s, width.to_s,
          '--setProperty', 'formatOptions', QUALITY,
          source.to_s, '--out', target.to_s
        )
        status.success? && File.size?(target) ? target : nil
      # SystemCallError covers Errno::ENOENT, which is the binary being absent.
      rescue SystemCallError
        nil
      end

      def dimensions(source, binary: BINARY)
        out, status = Open3.capture2e(binary, '-g', 'pixelWidth', '-g', 'pixelHeight', source.to_s)
        return [nil, nil] unless status.success?

        out.scan(/pixel(?:Width|Height):\s*(\d+)/).flatten.map(&:to_i)
      # SystemCallError covers Errno::ENOENT, which is the binary being absent.
      rescue SystemCallError
        [nil, nil]
      end

      private

      def scale_to_cover(source_width, source_height, width, height)
        wider = (source_width.to_f / source_height) > (width.to_f / height)
        wider ? ['--resampleHeight', height.to_s] : ['--resampleWidth', width.to_s]
      end

      public

      def available?(binary: BINARY)
        _, status = Open3.capture2e(binary, '--help')
        status.success?
      rescue Errno::ENOENT
        false
      end
    end
  end
end
