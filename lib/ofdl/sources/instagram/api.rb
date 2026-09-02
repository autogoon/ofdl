# frozen_string_literal: true

module OFDL
  module Sources
    class Instagram
      # Pagination over Instagram's private web API.
      #
      # Every endpoint but #reels takes the cookies and `x-ig-app-id` alone.
      # #reels is GraphQL and needs `fb_dtsg` as well; see Tokens.
      #
      # A name is turned into an id once, by #user, because stories, highlights
      # and the profile picture are all keyed by the numeric id.
      class Api
        PAGE = 12

        GRAPHQL_URL = 'https://www.instagram.com/api/graphql'

        def initialize(client:, tokens: nil)
          @client = client
          @tokens = tokens
        end

        # The profile, including the id stories and highlights are keyed by.
        def user(username)
          page = @client.get("/feed/user/#{username}/username/", { count: 1 })
          row = page['user'] or raise ApiError.new("no such account #{username.inspect}", path: username)

          row
        end

        # Newest first, so a page whose oldest row precedes `since` is the last
        # one worth asking for; see Api#exhausted?.
        def timeline(user_id, since: nil)
          Enumerator.new do |yielder|
            cursor = nil
            loop do
              params = { count: PAGE }
              params[:max_id] = cursor if cursor
              page = @client.get("/feed/user/#{user_id}/", params)
              rows = Array(page['items'])
              rows.each { yielder << it }
              break if exhausted?(rows, since)

              cursor = page['next_max_id'].to_s
              break unless page['more_available'] && !cursor.empty?
            end
          end
        end

        # The reels tab, which is not the timeline: most accounts' reels do not
        # appear in the grid #timeline reads.
        #
        # The reels tab is GraphQL, because Instagram serves no REST endpoint
        # for it; every other endpoint here is REST. What the query leaves out,
        # and what that costs, is at Sources::Instagram#walk_reels.
        REELS_QUERY = { doc_id: '28096073060084187', name: 'PolarisProfileReelsTabContentQuery' }.freeze

        def reels(user_id)
          Enumerator.new do |yielder|
            cursor = nil
            loop do
              page = reels_page(user_id, cursor)
              edges = Array(page['edges'])
              edges.each { yielder << it.dig('node', 'media') }

              info = page['page_info'] || {}
              cursor = info['end_cursor']
              break unless info['has_next_page'] && cursor
            end
          end
        end

        # One reel or post in full, including the video and the timestamp the
        # reels query leaves out.
        def media(media_id) = @client.get("/media/#{media_id}/info/")['items']&.first

        # One request, no pagination: a story tray holds at most a day of media.
        def stories(user_id) = reel_items(user_id.to_s)

        # The tray names the collections; each one's media is a second request.
        def highlights(user_id)
          Enumerator.new do |yielder|
            tray = @client.get("/highlights/#{user_id}/highlights_tray/")
            Array(tray['tray']).each do |collection|
              reel_items(collection['id']).each { yielder << it }
            end
          end
        end

        # The profile picture, as a row shaped like a media row so it flattens
        # the same way. `profile_pic_id` is "<media>_<user>", and the media half
        # changes when the picture does, which is what makes a new one a new
        # file rather than the same key.
        def avatar(user_id)
          row = @client.get("/users/#{user_id}/info/")['user'] || {}
          url = row.dig('hd_profile_pic_url_info', 'url') || row['profile_pic_url']
          pk = row['profile_pic_id'].to_s[/\A\d+/]
          return [] unless url && pk

          [{ 'pk' => pk, 'media_type' => Media::PHOTO, 'product_type' => 'avatar',
             'image_versions2' => { 'candidates' => [{ 'url' => url, 'width' => 1 }] } }]
        end

        private

        def reels_page(user_id, cursor)
          variables = {
            data: { include_feed_video: true, page_size: PAGE, target_user_id: user_id.to_s }.tap do |data|
              data[:after] = cursor if cursor
            end,
            user_id: user_id.to_s,
            __relay_internal__pv__PolarisShortDramaEnabledrelayprovider: false
          }
          page = graphql(REELS_QUERY, variables)
          page.dig('data', 'fetch__XDTUserDict', 'clips_connection') || {}
        end

        # The site sends a dozen underscore-prefixed fields with every GraphQL
        # call; these are the ones the endpoint rejects the request without.
        def graphql(query, variables)
          @client.post(
            GRAPHQL_URL,
            { av: '0', __d: 'www', __user: '0', __a: '1', dpr: '2',
              fb_dtsg: @tokens.fb_dtsg, doc_id: query[:doc_id], variables: JSON.generate(variables) },
            extra: { 'x-fb-friendly-name' => query[:name] }
          )
        end

        def reel_items(reel_id)
          page = @client.get('/feed/reels_media/', { reel_ids: reel_id })
          Array(page.dig('reels', reel_id, 'items'))
        end

        def exhausted?(rows, since)
          return false unless since && rows.any?

          Time.at(rows.last['taken_at'].to_i) < since
        end
      end
    end
  end
end
