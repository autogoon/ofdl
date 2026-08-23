# frozen_string_literal: true

module OFDL
  # Supplies the two request headers that are not derived from the signature:
  # `x-of-rev` and `x-hash`.
  #
  # Both come from the OnlyFans web client. In its bundle:
  #
  #   t["x-of-rev"] = "202608211829-e25f858429";
  #   const {hash: r} = G.A.state.hash;  r && (t["x-hash"] = r);
  #
  # The revision is a literal in each build, and appears in every asset URL on
  # the page. It is read back out of the homepage rather than pinned here,
  # because a pinned value goes stale on OnlyFans' next deploy.
  #
  # The hash is fetched from a CDN endpoint the client calls with
  # `withCredentials: false`:
  #
  #   r.Ay.get(`https://cdn2.onlyfans.com/hash/?u=${e}`, {withCredentials: !1})
  #
  # Neither request carries cookies. Both go through curl-impersonate, because
  # the same Cloudflare edge sits in front of them.
  class SiteState
    HOME_URL = 'https://onlyfans.com/'
    HASH_URL = 'https://cdn2.onlyfans.com/hash/'

    # Matches the revision in any asset URL: static/prod/<channel>/<rev>/...
    REVISION_PATTERN = %r{static/prod/[a-z]+/(\d{12}-[0-9a-f]+)/}

    # The web client's own window: fetchHash returns early while
    # hashTimeStamp + 1e4 > now.
    HASH_TTL_SECONDS = 10

    def initialize(transport:, auth_id:, log:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @transport = transport
      @auth_id = auth_id
      @log = log
      @clock = clock
      @mutex = Mutex.new
    end

    # Fixed for the life of a build, so fetched once per run.
    def revision
      @mutex.synchronize { @revision ||= fetch_revision }
    end

    def content_hash
      @mutex.synchronize do
        now = @clock.call
        if @content_hash.nil? || @fetched_at.nil? || (now - @fetched_at) >= HASH_TTL_SECONDS
          @content_hash = fetch_hash
          @fetched_at = now
        end
        @content_hash
      end
    end

    # Headers to merge into a request. `x-hash` is omitted when unavailable,
    # matching the client, which only sets it when truthy.
    def headers
      { 'x-of-rev' => revision }.tap do |built|
        value = content_hash
        built['x-hash'] = value unless value.to_s.empty?
      end
    end

    private

    def fetch_revision
      response = @transport.get(HOME_URL, {})
      unless response.success?
        raise ApiError.new("could not read the OnlyFans build revision: HTTP #{response.status}",
                           status: response.status, path: HOME_URL)
      end

      revision = response.body[REVISION_PATTERN, 1]
      raise ApiError.new("no build revision found in #{HOME_URL}", path: HOME_URL) unless revision

      @log.debug("x-of-rev: #{revision}")
      revision
    end

    # A failure here is not fatal: the web client leaves the header off when its
    # own fetch fails.
    def fetch_hash
      response = @transport.get("#{HASH_URL}?u=#{@auth_id}", {})
      unless response.success?
        @log.warn("x-hash unavailable (HTTP #{response.status}); continuing without it")
        return nil
      end

      # text/plain, base64-shaped: "HASHVALUE..."
      response.body.to_s.strip
    rescue ApiError => e
      @log.warn("x-hash unavailable (#{e.message}); continuing without it")
      nil
    end
  end
end
