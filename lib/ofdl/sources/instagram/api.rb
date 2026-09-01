# frozen_string_literal: true

module OFDL
  module Sources
    class Instagram
      # Pagination over Instagram's private web API.
      #
      # These are the endpoints the web client calls that need no per-page-load
      # token. The GraphQL endpoint the site itself mostly uses wants `fb_dtsg`
      # and `lsd`, both minted into each HTML response; these take only the
      # cookies and `x-ig-app-id`.
      #
      # A name is turned into an id once, by #user, because stories, highlights
      # and the profile picture are all keyed by the numeric id.
      class Api
        PAGE = 12

        def initialize(client:)
          @client = client
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
