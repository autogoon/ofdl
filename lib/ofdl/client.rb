# frozen_string_literal: true

require 'json'
require 'uri'

module OFDL
  # OnlyFans invalidates the session on bursts, so the configured default is two
  # requests a second.
  class RateLimiter
    def initialize(per_second)
      @interval = 1.0 / per_second
      @mutex = Mutex.new
      @next_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait
      delay = @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        slot = [@next_at, now].max
        @next_at = slot + @interval
        slot - now
      end
      sleep(delay) if delay.positive?
    end
  end

  # Authenticated JSON client for the OnlyFans private API.
  #
  # Cookies go to onlyfans.com and nowhere else. Media downloads do not use this
  # class at all; see Downloader.
  class Client
    BASE = 'https://onlyfans.com/api2/v2'
    HOST = 'onlyfans.com'
    MAX_ATTEMPTS = 4
    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

    # A rejected request is the only reliable signal that the signing rules have
    # rotated. These are the statuses OnlyFans uses for a signature it will not
    # accept -- 401/403 also cover a dead session; see refresh_rules!.
    STALE_RULES_STATUSES = [400, 401, 403].freeze

    def initialize(jar:, transport:, rate_limiter:, log:, base: BASE, signer: nil, site_state: nil,
                   stats: nil, refresh_signer: nil, extra_headers: {})
      @jar = jar
      @base = base
      @signer = signer
      @extra_headers = extra_headers
      @transport = transport
      @rate_limiter = rate_limiter
      @log = log
      @site_state = site_state
      @stats = stats
      @refresh_signer = refresh_signer
      @refreshed = false
      @refresh_mutex = Mutex.new
    end

    def get(path, params = {})
      uri = build_uri(path, params)
      request_path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path

      with_retries(path) do
        @rate_limiter.wait
        handle(perform(uri, request_path), path)
      end
    end

    private

    # The signed string is the /api2/v2 path plus the serialised query, and
    # nothing else. There is no `u=<auth_id>` parameter: that belongs to other
    # OnlyFans endpoints (see SiteState::HASH_URL), not to /api2/v2 calls, and
    # sending it here gets the request rejected.
    def build_uri(path, params)
      uri = URI("#{@base}#{path}")
      query = params.compact.transform_keys(&:to_s)
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    # curl-impersonate's profile is a *document navigation*: it sends
    # "sec-fetch-mode: navigate", "sec-fetch-dest: document" and
    # "upgrade-insecure-requests: 1". These calls are XHR, so those are
    # corrected here. A header given an empty value is removed by curl.
    #
    # The User-Agent reports the installed Chrome rather than the impersonated
    # profile; see Chrome.
    XHR_HEADERS = {
      'accept' => 'application/json, text/plain, */*',
      'sec-fetch-site' => 'same-origin',
      'sec-fetch-mode' => 'cors',
      'sec-fetch-dest' => 'empty',
      'priority' => 'u=1, i',
      'upgrade-insecure-requests' => ''
    }.freeze

    # `private` above does not reach constants, so say it here.
    private_constant :XHR_HEADERS

    # `x-of-rev` and `x-hash` are not part of the signature, but the web client
    # sends them on every /api2/v2 call; see SiteState.
    #
    # A source with no request signing passes no signer and carries whatever
    # its own client sends in `extra_headers` -- for Instagram, `x-ig-app-id`.
    def headers(request_path)
      (@signer&.headers_for(request_path) || {})
        .merge(XHR_HEADERS)
        .merge(@site_state&.headers || {})
        .merge(@extra_headers)
        .merge('user-agent' => Chrome.user_agent, 'cookie' => @jar.header)
    end

    def perform(uri, request_path)
      sent = headers(request_path)
      # Enumeration is paced at a couple of requests a second, so one line each
      # stays readable.
      @stats&.bump(:requests)
      @log.request(request_path)
      @log.debug { "GET #{uri}\n#{sent.map { |k, v| "  #{k}: #{v}" }.join("\n")}" }
      @transport.get(uri.to_s, sent)
    end

    # OnlyFans returns a reason in the response body -- {"error":{"code":..,
    # "message":".."}} -- so a status code alone discards the only useful
    # diagnostic.
    def handle(response, path)
      return parse(response, path) if response.success?

      raise ApiError.new("HTTP #{response.status}#{detail(response)}", status: response.status, path:)
    end

    def detail(response)
      body = response.body.to_s.strip
      return '' if body.empty?

      " -- #{body.byteslice(0, 400)}"
    end

    # At most once per run: if fresh rules do not help, the problem is the
    # session, not the rules.
    def refresh_rules!
      @refresh_mutex.synchronize do
        return false if @refreshed || @refresh_signer.nil?

        @refreshed = true
        @log.warn('signature rejected -- refetching signing rules and retrying once')
        @signer = @refresh_signer.call
        true
      end
    rescue RulesError => e
      @log.warn("rules refresh failed: #{e.message}")
      false
    end

    def rejected_error(error)
      ApiError.new(
        "#{error.message}\n  " \
        '(still rejected after refreshing the signing rules -- either the session ' \
        'has expired, or the signing algorithm has changed)',
        status: error.status, path: error.path
      )
    end

    def parse(response, path)
      body = response.body.to_s
      return {} if body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      raise ApiError.new("non-JSON response (#{body.byteslice(0, 120).inspect})", path:)
    end

    def with_retries(path)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue ApiError => e
        # Only a signed request can be rejected for its signature, so a source
        # with no signer takes these as the plain errors they are.
        if @signer && STALE_RULES_STATUSES.include?(e.status)
          raise rejected_error(e) unless refresh_rules!

          retry
        end
        raise unless RETRY_STATUSES.include?(e.status) && attempt < MAX_ATTEMPTS

        backoff = 2**attempt
        @log.warn("#{path}: #{e.message}; retry #{attempt}/#{MAX_ATTEMPTS - 1} in #{backoff}s")
        sleep(backoff)
        retry
      rescue SystemCallError, IOError => e
        raise ApiError.new(e.message, path:) unless attempt < MAX_ATTEMPTS

        backoff = 2**attempt
        @log.warn("#{path}: #{e.class} #{e.message}; retry #{attempt}/#{MAX_ATTEMPTS - 1} in #{backoff}s")
        sleep(backoff)
        retry
      end
    end
  end
end
