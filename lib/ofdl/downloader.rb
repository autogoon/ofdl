# frozen_string_literal: true

module OFDL
  Outcome = Data.define(:item, :status, :bytes, :message) do
    def ok? = status == :downloaded
  end

  # Fetches media to disk.
  #
  # Downloads land in local scratch space and are copied into the output
  # directory only once complete; see Scratch for why.
  class Downloader
    MAX_ATTEMPTS = 3
    RETRY_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    def initialize(library:, config:, log:, transport:, scratch:, stats: nil, preview: nil)
      @library = library
      @config = config
      @log = log
      @transport = transport
      @scratch = scratch
      @stats = stats
      @preview = preview
    end

    def call(item, username:, slot: 0)
      return Outcome.new(item:, status: :skipped, bytes: 0, message: 'already present') if @library.have?(item,
                                                                                                          username:)

      return protected_outcome(item, username:) if item.protected?

      destination = @library.prepare(item, username:)
      bytes = item.streaming? ? remux(item, destination) : fetch(item, destination, slot, username)
      @library.record(item, username:)
      Outcome.new(item:, status: :downloaded, bytes:, message: nil)
    rescue DownloadError => e
      Outcome.new(item:, status: :failed, bytes: 0, message: e.message)
    end

    private

    def protected_outcome(item, username:)
      unless @config.skip_protected?
        raise DownloadError, 'protected video and skip_protected is false, but this tool cannot decrypt DRM'
      end

      @library.write_marker(item, username:) if @config.mark_protected?
      Outcome.new(item:, status: :protected, bytes: 0, message: 'Widevine-protected video')
    end

    def remux(item, destination)
      Remux.call(item.url, destination, ffmpeg: @config.ffmpeg)
      destination.size
    end

    # Media URLs are CloudFront-signed and unauthenticated, so the download
    # sends no cookies and no session headers -- a leaked media URL grants one
    # file until its signature expires.
    def fetch(item, destination, slot, username)
      working = @scratch.path_for(item)
      headers = @scratch.headers_for(item)
      attempt = 0

      begin
        attempt += 1
        # The dashboard reads live progress by stat()ing the scratch file, and
        # takes the total from the header file curl fills in before the body
        # arrives.
        @stats&.begin_download(slot, filename: item.filename, path: working, total: item.size,
                                     headers_path: headers, creator: username, post_type: item.post_type)
        verify!(@transport.download(item.url, working, dump_headers: headers), item)

        # Drawn before the copy: publishing to a mounted share takes time, so a
        # preview drawn after it appears long after the download it belongs to
        # finished.
        if item.image?
          @stats&.phase(slot, :rendering)
          @preview&.show(slot, working)
        end

        @stats&.phase(slot, :moving)
        bytes = @scratch.publish(working, destination)
        @scratch.clear(working)
        bytes
      rescue DownloadError => e
        @scratch.clear(working)
        raise unless e.retryable? && attempt < MAX_ATTEMPTS

        @log.debug("#{item.key}: #{e.message}; retry #{attempt}/#{MAX_ATTEMPTS - 1}")
        sleep(2**attempt)
        retry
      ensure
        @stats&.finish_download(slot)
        @scratch.clear(headers)
      end
    end

    def verify!(status, item)
      return if (200..299).cover?(status)

      hint = status == 403 ? ' (CloudFront signature expired -- rerun to refresh it)' : ''
      raise DownloadError.new("HTTP #{status} for #{item.key}#{hint}", retryable: RETRY_STATUSES.include?(status))
    end
  end
end
