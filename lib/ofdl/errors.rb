# frozen_string_literal: true

module OFDL
  # Base for the errors this tool raises itself. CLI#run rescues these and
  # prints the message without a backtrace; every exception other than Interrupt
  # escapes to Ruby's default handler, which prints one.
  class Error < StandardError; end

  class ConfigError < Error; end
  class CookieError < Error; end
  class RulesError < Error; end

  # A rejected API call. `status` and `path` are carried so the retry in
  # Client#with_retries can decide whether a refetch of the signing rules is
  # worth trying before giving up.
  class ApiError < Error
    attr_reader :status, :path

    def initialize(message, status: nil, path: nil)
      super(message)
      @status = status
      @path = path
    end
  end

  # A failed transfer. `retryable` is what Downloader#fetch consults before
  # spending another of its MAX_ATTEMPTS; anything else fails on the first try.
  class DownloadError < Error
    attr_reader :retryable

    def initialize(message, retryable: false)
      super(message)
      @retryable = retryable
    end

    def retryable? = @retryable
  end
end
