# frozen_string_literal: true

require 'open3'

module OFDL
  # Container conversion for unprotected items OnlyFans serves as HLS/DASH
  # rather than a plain file. Stream copy only -- no re-encoding.
  module Remux
    class << self
      def available?(ffmpeg)
        _, status = Open3.capture2e(ffmpeg, '-version')
        status.success?
      rescue Errno::ENOENT
        false
      end

      # ffmpeg cannot infer a muxer from a ".part" suffix, so the format is
      # named explicitly.
      def call(url, destination, ffmpeg:)
        partial = Pathname("#{destination}.part")
        command = [
          ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
          '-i', url.to_s,
          '-c', 'copy', '-movflags', '+faststart',
          '-f', 'mp4', partial.to_s
        ]

        output, status = Open3.capture2e(*command)
        unless status.success?
          partial.delete if partial.exist?
          raise DownloadError, "ffmpeg failed (#{status.exitstatus}): #{output.lines.last(3).join.strip}"
        end

        partial.rename(destination)
        destination
      rescue Errno::ENOENT
        raise DownloadError, "ffmpeg not found at #{ffmpeg.inspect} -- set \"ffmpeg\" in the config"
      end
    end
  end
end
