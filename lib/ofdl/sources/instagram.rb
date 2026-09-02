# frozen_string_literal: true

module OFDL
  module Sources
    # Everything a run needs that is particular to Instagram.
    #
    # There is no request signing and no subscription list: a public account
    # can be read without following it, so a creator is named on the command
    # line rather than looked up in a list of your own.
    class Instagram
      KEY = Source::INSTAGRAM

      BASE = 'https://www.instagram.com/api/v1'

      # The web client's own application id, a literal in its bundle. Every
      # endpoint below refuses the request without it.
      APP_ID = '936619743392459'

      COOKIES = Cookies::Site.new(
        host: 'instagram.com',
        lead: %w[csrftoken sessionid ds_user_id mid ig_did datr],
        required: %w[sessionid ds_user_id csrftoken]
      )

      POST_TYPES = %w[posts reels stories highlights avatar].freeze

      def initialize(config:, log:, stats:, transport:)
        @config = config
        @log = log
        @stats = stats
        @transport = transport
      end

      def key = KEY

      def post_types = POST_TYPES

      # No list of your own to enumerate: `ofdl fetch` on Instagram takes names.
      def creators = []

      # Any public account, whether or not you follow it. A private account you
      # do not follow fails on the first request instead, because whether it
      # can be read is the account's setting rather than a property of the name.
      def resolve(username)
        { source: KEY, id: api.user(username)['pk'], username: }
      end

      def items_from(row, post_type:) = Media.from_row(row, post_type:)

      # An `@handle` in an Instagram caption is ordinary, so no post here is
      # read as an advert; `--include-ads` and `skip_ads` do not apply.
      def advert_reason(_row, creator: nil) = nil

      # The timeline is the grid, and a grid may hold reels: an account can
      # have a reel in both places, or reels the grid never shows. So `posts`
      # walks the timeline and `reels` walks the reels tab, and a reel found in
      # both is deduplicated by key like any other repeat; see
      # Session#verdict_for.
      def each_row(post_types, user_id, since: nil, present: nil)
        walk_timeline(user_id, since:) { |row| yield 'posts', row } if post_types.include?('posts')
        walk_reels(user_id, since:, present:) { |row| yield 'reels', row } if post_types.include?('reels')

        (post_types - %w[posts reels]).each do |post_type|
          rows_for(post_type, user_id).each { yield post_type, it }
        rescue ApiError => e
          @log.warn("#{post_type}: #{e.message} -- continuing without it")
        end
      end

      def status_lines
        yield ['cookies', "#{jar.values.size} for instagram.com (#{jar.values.keys.sort.join(', ')})"]
        yield ['ds_user_id', jar['ds_user_id']]
        yield ['x-ig-app-id', APP_ID]
      end

      def jar = @jar ||= Cookies.load(site: COOKIES, profile: @config.chrome_profile)

      def client
        @client ||= Client.new(
          jar:, transport: @transport, stats: @stats, base: BASE, log: @log,
          rate_limiter: RateLimiter.new(@config.requests_per_second),
          extra_headers: { 'x-ig-app-id' => APP_ID, 'referer' => 'https://www.instagram.com/' }
        )
      end

      def tokens = @tokens ||= Tokens.new(transport: @transport, jar:, log: @log)

      def api = @api ||= Api.new(client:, tokens:)

      private

      def walk_timeline(user_id, since:, &)
        api.timeline(user_id, since:).each(&)
      rescue ApiError => e
        @log.warn("posts: #{e.message} -- continuing without it")
      end

      # The reels listing carries each reel's thumbnail but neither its video
      # nor its timestamp, so a reel needs a second request to be downloadable.
      # That request is made only when a key is missing from the library: a
      # rerun over an archived account makes none of them.
      #
      # `since` cannot end the walk early. The listing has no timestamp to
      # compare, and the only row that carries one is the row a request has
      # already been spent on -- so the pages are walked to the end and Session
      # drops what is too old.
      def walk_reels(user_id, since:, present:)
        api.reels(user_id).each do |summary|
          pk = summary['pk'] or next
          next if present && Media.keys_for(pk).all? { present.call('reels', it) }

          row = api.media(pk) or next
          yield row
        end
      rescue ApiError => e
        @log.warn("reels: #{e.message} -- continuing without it")
      end

      def rows_for(post_type, user_id)
        case post_type
        when 'stories' then api.stories(user_id)
        when 'highlights' then api.highlights(user_id)
        when 'avatar' then api.avatar(user_id)
        else raise ConfigError, "unknown post type #{post_type.inspect}"
        end
      end
    end
  end
end
