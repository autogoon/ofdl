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

      # The accounts you follow, which `ofdl subs` prints and `ofdl fetch`
      # walks when no names are given.
      def creators
        api.following(viewer_id).map { { source: KEY, id: it['pk'], username: it['username'] } }
      end

      # The signed-in account's own id, which Instagram keeps in a cookie.
      def viewer_id = jar['ds_user_id']

      # Any account, followed or not: Instagram shows a public account to
      # anyone, so following decides how much is visible rather than whether
      # anything is. #note_visibility says which case this is.
      #
      # The id comes from the grid, whose rows name the account they belong to,
      # or from the follow list for an account whose grid is empty.
      # `/feed/user/<name>/username/`, which answered this in one request,
      # answers 302 to the site root; see Api::GRID_QUERY.
      def resolve(username)
        id = grid_id(username) || followed_id(username)
        raise ConfigError, "instagram/#{username}: no such account, or nothing about it is readable" unless id

        note_visibility(username, id)
        { source: KEY, id:, username: }
      end

      def items_from(row, post_type:) = Media.from_row(row, post_type:)

      # An `@handle` in an Instagram caption is ordinary, so no post here is
      # read as an advert; `--include-ads` and `skip_ads` do not apply.
      def advert_reason(_row, creator: nil) = nil

      # The feeds read newest first, and so the ones a run can stop part way
      # through; see Session#count_idle. A story tray and a highlight tray page
      # over collections rather than dates, and an avatar is a single row.
      ORDERED = %w[posts reels].freeze

      def ordered?(post_type) = ORDERED.include?(post_type)

      # The timeline is the grid, and a grid may hold reels: an account can
      # have a reel in both places, or reels the grid never shows. So `posts`
      # walks the timeline and `reels` walks the reels tab, and a reel found in
      # both is deduplicated by key like any other repeat; see
      # Session#verdict_for.
      #
      # Each feed is caught separately, so one ended early by Session leaves
      # the others to be walked; see Session#count_idle.
      def each_row(post_types, user_id, since: nil, cutoff: nil, present: nil, username: nil)
        if post_types.include?('posts')
          catch(:stop_feed) { walk_timeline(username, since:) { |row| yield 'posts', row } }
        end
        catch(:stop_feed) { walk_reels(user_id, present:) { |row| yield 'reels', row } } if post_types.include?('reels')

        (post_types - %w[posts reels]).each do |post_type|
          catch(:stop_feed) { rows_for(post_type, user_id, cutoff:).each { yield post_type, it } }
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
          # The grid query answers 403 with an HTML body without `x-csrftoken`,
          # which the web client sends on every request from the cookie of the
          # same name.
          extra_headers: { 'x-ig-app-id' => APP_ID, 'referer' => 'https://www.instagram.com/',
                           'x-csrftoken' => jar['csrftoken'].to_s }
        )
      end

      def tokens = @tokens ||= Tokens.new(transport: @transport, jar:, log: @log)

      def api = @api ||= Api.new(client:, tokens:)

      private

      # One request. An account with no posts answers with no rows and so no
      # id, which is what sends #resolve to the follow list.
      def grid_id(username)
        api.timeline(username).first&.dig('user', 'pk')
      rescue ApiError => e
        @log.debug("#{username}: could not read the grid (#{e.message})")
        nil
      end

      # The whole follow list, which costs a request per 25 accounts. Read only
      # when the grid answered nothing.
      def followed_id(username)
        creators.find { it[:username].to_s.casecmp?(username.to_s) }&.fetch(:id)
      rescue ApiError => e
        @log.debug("#{username}: could not read the follow list (#{e.message})")
        nil
      end

      # One request, made only for a creator named on the command line: the
      # follow list needs no such check, because being on it is the answer.
      #
      # A private account shows a non-follower nothing at all, so that case is
      # named apart from a public one, where not following costs some of the
      # feeds rather than all of them.
      def note_visibility(username, user_id)
        status = api.friendship(user_id)
        return if status['following']

        if status['is_private']
          @log.warn("  #{KEY}/#{username} is private and you do not follow it -- nothing will be readable")
        else
          @log.warn("  #{KEY}/#{username}: follow this creator to get all of their content")
        end
      rescue ApiError => e
        @log.debug("#{username}: could not read follow status (#{e.message})")
      end

      # A target with no username is skipped: Api::GRID_QUERY names the account
      # by username, and the numeric id the other endpoints take does not
      # identify it to that query.
      def walk_timeline(username, since:, &)
        return @log.warn('posts: no username for this creator -- continuing without it') if username.nil?

        api.timeline(username, since:).each(&)
      rescue ApiError => e
        @log.warn("posts: #{e.message} -- continuing without it")
      end

      # The reels listing carries each reel's thumbnail but neither its video
      # nor its timestamp, so a reel needs a second request, to Api#media,
      # before it can be downloaded. Under `--all` that request is made only
      # when a key is missing from the library, so a rerun over an archived
      # account makes none. Under every other mode `present` answers false: a
      # reel already on disk is what ends the walk, and Session never sees one
      # the adapter has dropped; see Session#presence.
      #
      # The listing gives both the pk the library keys on and the shortcode
      # Api#media takes.
      def walk_reels(user_id, present:)
        api.reels(user_id).each do |summary|
          pk = summary['pk'] or next
          code = summary['code'] or next
          next if present && Media.keys_for(pk).all? { present.call('reels', it) }

          row = api.media(code) or next
          yield row
        end
      rescue ApiError => e
        @log.warn("reels: #{e.message} -- continuing without it")
      end

      def rows_for(post_type, user_id, cutoff:)
        case post_type
        when 'stories' then api.stories(user_id)
        when 'highlights' then api.highlights(user_id, since: cutoff&.call('highlights'))
        when 'avatar' then api.avatar(user_id)
        else raise ConfigError, "unknown post type #{post_type.inspect}"
        end
      end
    end
  end
end
