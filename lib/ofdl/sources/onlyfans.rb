# frozen_string_literal: true

module OFDL
  module Sources
    # Everything a run needs that is particular to OnlyFans: the session, the
    # request signing, which feeds exist and how each is paged.
    #
    # Built lazily so `ofdl status` can report the environment and the library
    # before `jar` brings up the Keychain prompt, and so an auth failure
    # surfaces before any enumeration starts.
    #
    # Session owns what every app shares -- the transport, the library, the
    # scratch directory, the download pool -- and holds one of these per app.
    class OnlyFans
      KEY = Source::ONLYFANS

      # `auth_id` identifies the account and `fp` doubles as the `x-bc` request
      # header; see Signer#headers_for.
      COOKIES = Cookies::Site.new(
        host: 'onlyfans.com',
        lead: %w[csrf fp sess auth_id st ref_src],
        required: %w[auth_id fp sess]
      )

      # The feeds, in the order a run walks them. `archived` and `paid` are
      # OnlyFans' own; no other app has anything answering to them.
      POST_TYPES = %w[posts messages stories highlights paid archived].freeze

      def initialize(config:, log:, stats:, transport:)
        @config = config
        @log = log
        @stats = stats
        @transport = transport
      end

      def key = KEY

      def post_types = POST_TYPES

      # Targets, in the shape Session#produce takes. Deduplicated because the
      # same creator can appear on more than one page of the subscription list,
      # and archiving one twice would walk every feed twice.
      def creators
        api.subscriptions.to_a.uniq { it['id'] }.map { { source: KEY, id: it['id'], username: it['username'] } }
      end

      # A creator has to be subscribed to: OnlyFans shows a non-subscriber
      # nothing to download.
      def resolve(username)
        row = creators.find { it[:username].to_s.downcase == username.downcase }
        row or raise ConfigError, "not subscribed to #{username.inspect} on #{KEY} (run `ofdl subs`)"
      end

      def items_from(row, post_type:) = Media.from_row(row, source: KEY, post_type:)

      # Posts that advertise another creator; see Advert.
      def advert_reason(row, creator:) = Advert.reason(row, creator:)

      # Every row of every feed asked for, each tagged with the post type it
      # was read under. One feed per post type here; an app whose one listing
      # carries several post types yields them interleaved instead.
      #
      # `present` goes unused: an OnlyFans row arrives with its media's URLs in
      # it, so no request is deferred until the library has been consulted.
      #
      # A feed that raises is skipped; the remaining feeds are still read.
      def each_row(post_types, user_id, since: nil, present: nil)
        post_types.each do |post_type|
          feed(post_type, user_id, since:).each { yield post_type, it }
        rescue ApiError => e
          @log.warn("#{post_type}: #{e.message} -- continuing without it")
        end
      end

      # What `ofdl status` prints for this app, as label/value pairs.
      #
      # Yielded one at a time, with the /users/me request last. An expired
      # session fails on that request, and the cookie, auth_id, x-bc and rules
      # pairs show which part of the session was sent. Building the pairs into
      # an array would raise before any of them reached the screen.
      def status_lines
        yield ['cookies', "#{jar.values.size} for onlyfans.com (#{jar.values.keys.sort.join(', ')})"]
        yield ['auth_id', auth_id]
        yield ['x-bc', Display.truncate(xbc)]
        yield ['rules', "static_param #{Display.truncate(rules.static_param)}, " \
                        "#{rules.checksum_indexes.size} checksum indexes"]

        me = api.me
        username = me['username'] || me['name']
        raise ApiError, "authenticated, but /users/me returned no username: #{me.inspect}" unless username

        yield ['signed in', "@#{username} (id #{me['id']}), #{me['subscribesCount']} subscriptions"]
      end

      def jar = @jar ||= Cookies.load(site: COOKIES, profile: @config.chrome_profile)

      def auth_id = jar['auth_id']

      def xbc = jar['fp']

      def rules_store = @rules_store ||= RulesStore.new(config: @config, log: @log)

      def rules = @rules ||= rules_store.load

      def signer = @signer ||= build_signer(rules)

      def site_state
        @site_state ||= SiteState.new(transport: @transport, auth_id: auth_id, log: @log)
      end

      def client
        @client ||= Client.new(
          jar:, signer:, transport: @transport, site_state:, stats: @stats,
          rate_limiter: RateLimiter.new(@config.requests_per_second),
          log: @log,
          extra_headers: { 'referer' => 'https://onlyfans.com/' },
          refresh_signer: -> { refresh_signer! }
        )
      end

      def api = @api ||= Api.new(client:)

      # Handed to the Client so a rejected signature can be retried with freshly
      # fetched rules exactly once.
      def refresh_signer!
        @rules = rules_store.refresh!
        @signer = build_signer(@rules)
      end

      private

      # `since` reaches only the feeds ordered newest-first, which are the ones
      # that can stop early on it; see Api#exhausted?.
      def feed(post_type, user_id, since:)
        case post_type
        when 'posts' then api.posts(user_id, since:)
        when 'archived' then api.posts(user_id, archived: true, since:)
        when 'messages' then api.messages(user_id, since:)
        when 'paid' then api.paid(user_id, since:)
        when 'stories' then api.stories(user_id)
        when 'highlights' then api.highlights(user_id)
        else raise ConfigError, "unknown post type #{post_type.inspect}"
        end
      end

      def build_signer(rules) = Signer.new(rules:, user_id: auth_id, xbc: xbc)
    end
  end
end
