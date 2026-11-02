# frozen_string_literal: true

module OFDL
  module Sources
    class Instagram
      # Pagination over Instagram's private web API.
      #
      # The REST endpoints take the cookies and `x-ig-app-id` alone. The
      # GraphQL ones -- #timeline, #reels, #media, #stories, #highlights and
      # #avatar -- need `fb_dtsg` as well; see Tokens.
      #
      # A name is turned into an id once, by #user, because stories, highlights
      # and the profile picture are all keyed by the numeric id.
      class Api
        PAGE = 12

        # The page size the web client asks for on a list of accounts.
        PAGE_USERS = 25

        GRAPHQL_URL = 'https://www.instagram.com/api/graphql'

        def initialize(client:, tokens: nil)
          @client = client
          @tokens = tokens
        end

        # The accounts one viewer follows. `user_id` is the signed-in viewer's
        # own id, which is the `ds_user_id` cookie.
        def following(user_id)
          Enumerator.new do |yielder|
            cursor = nil
            loop do
              params = { count: PAGE_USERS }
              params[:max_id] = cursor if cursor
              page = @client.get("/friendships/#{user_id}/following/", params)
              rows = Array(page['users'])
              rows.each { yielder << it }

              cursor = page['next_max_id']
              break if rows.empty?
              break unless page['has_more'] && cursor
            end
          end
        end

        # Whether the viewer follows one account, and whether it is private.
        def friendship(user_id) = @client.get("/friendships/show/#{user_id}/")

        # The grid, which Instagram serves only over GraphQL: `/feed/user/<id>/`
        # answers 302 to the site root for every account. The variables name the
        # account by username; every REST endpoint here takes the numeric id.
        GRID_QUERY = { doc_id: '27954396937596316',
                       name: 'PolarisProfilePostsTabContentQuery_connection' }.freeze

        # Newest first, so a page whose oldest row precedes `since` is the last
        # one worth asking for; see Api#exhausted?.
        def timeline(username, since: nil)
          Enumerator.new do |yielder|
            cursor = nil
            number = 0
            loop do
              number += 1
              page = grid_page(username, cursor, number)
              rows = Array(page['edges']).filter_map { it['node'] }
              rows.each { yielder << it }

              info = page['page_info'] || {}
              cursor = info['end_cursor']
              break if rows.empty? || exhausted?(rows, since)
              break unless info['has_next_page'] && cursor
            end
          end
        end

        # The reels tab, which is not the timeline: an account's reels need not
        # appear in the grid #timeline reads.
        #
        # What the query leaves out, and what that costs, is at
        # Sources::Instagram#walk_reels.
        REELS_QUERY = { doc_id: '28096073060084187', name: 'PolarisProfileReelsTabContentQuery' }.freeze

        def reels(user_id)
          Enumerator.new do |yielder|
            cursor = nil
            number = 0
            loop do
              number += 1
              page = reels_page(user_id, cursor, number)
              edges = Array(page['edges'])
              edges.each { yielder << it.dig('node', 'media') }

              info = page['page_info'] || {}
              cursor = info['end_cursor']
              # An empty page ends the walk whatever has_next_page says: a
              # cursor that stops advancing would otherwise be requested until
              # the run is killed.
              break if edges.empty?
              break unless info['has_next_page'] && cursor
            end
          end
        end

        # One reel or post in full, including the video and the timestamp the
        # reels query leaves out. Keyed by the shortcode a listing row carries
        # as `code`, because `/media/<pk>/info/` answers 302 to the site root.
        #
        # The two provider flags are the ones the query refuses to run without:
        # dropping either answers `items: []` and a missing_required_variable
        # error, while the other three the web client sends make no difference.
        POST_QUERY = { doc_id: '28499995702964365', name: 'PolarisPostRootQuery' }.freeze

        def media(code)
          variables = {
            shortcode: code.to_s, fetch_tagged_user_count: nil, hoisted_comment_id: nil, hoisted_reply_id: nil,
            __relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider: true,
            __relay_internal__pv__PolarisShortDramaEnabledrelayprovider: false
          }
          page = graphql(POST_QUERY, variables, label: "media #{code}")
          page.dig('data', 'xdt_api__v1__media__shortcode__web_info', 'items')&.first
        end

        # The query behind both story trays, because `/feed/reels_media/` answers
        # 500 to every request. `reel_ids` holds user ids for stories and
        # `highlight:<id>` ids for highlights.
        REELS_MEDIA_QUERY = { doc_id: '29299425373007309', name: 'PolarisStoriesV3HighlightsPageQuery' }.freeze

        # The query answers at most 10 reels whatever `first` says. Its cursor
        # repeats reels from the page before, so the ids are split rather than paged.
        REELS_PER_REQUEST = 10

        # One request, no pagination: a story tray holds at most a day of media.
        def stories(user_id) = reels_media([user_id.to_s]).flat_map { Array(it['items']) }

        # The tray over GraphQL, because `/highlights/<id>/highlights_tray/`
        # answers 302 to the site root. It names the collections and no dates.
        HIGHLIGHTS_QUERY = { doc_id: '38168009559465141',
                             name: 'ProfileStoryHighlightsTrayContentQuery_connection' }.freeze

        HIGHLIGHTS_PER_TRAY_PAGE = 20

        # A reel carries `latest_reel_media`, the date of its newest story, so a
        # collection holding nothing newer than `since` yields nothing. The tray
        # is not in date order -- a creator arranges it -- so each collection is
        # tested rather than the walk ended; see Session#cutoff_for for where
        # the date comes from.
        def highlights(user_id, since: nil)
          Enumerator.new do |yielder|
            cursor = nil
            loop do
              variables = { user_id: user_id.to_s, first: HIGHLIGHTS_PER_TRAY_PAGE }
              variables[:after] = cursor if cursor
              page = graphql(HIGHLIGHTS_QUERY, variables, label: 'highlights tray')
              tray = page.dig('data', 'highlights') || {}
              ids = Array(tray['edges']).filter_map { it.dig('node', 'id') }
              break if ids.empty?

              ids.each_slice(REELS_PER_REQUEST) do |reel_ids|
                reels_media(reel_ids).each do |reel|
                  next if since && Time.at(reel['latest_reel_media'].to_i) < since

                  Array(reel['items']).each { yielder << it }
                end
              end

              info = tray['page_info'] || {}
              cursor = info['end_cursor']
              break unless info['has_next_page'] && cursor
            end
          end
        end

        # The profile page's own query: `/users/<id>/info/` answers 429 to every
        # request. The five provider flags carry the values the web client
        # sends.
        PROFILE_QUERY = { doc_id: '28036671149327607', name: 'PolarisProfilePageContentQuery' }.freeze

        # The profile picture, as a row shaped like a media row so it flattens
        # the same way.
        #
        # The query returns no `profile_pic_id`, so the key is the middle
        # number of the CDN filename, "<n>_<n>_<n>_n.jpg".
        def avatar(user_id)
          variables = {
            id: user_id.to_s, render_surface: 'PROFILE',
            __relay_internal__pv__PolarisCASB976ProfileEnabledrelayprovider: false,
            __relay_internal__pv__PolarisCannesGuardianExperienceEnabledrelayprovider: true,
            __relay_internal__pv__PolarisRepostsConsumptionEnabledrelayprovider: true,
            __relay_internal__pv__PolarisShortDramaEnabledrelayprovider: false,
            __relay_internal__pv__PolarisWebSchoolsEnabledrelayprovider: false
          }
          row = graphql(PROFILE_QUERY, variables, label: 'profile').dig('data', 'user') || {}
          url = row.dig('hd_profile_pic_url_info', 'url') || row['profile_pic_url']
          pk = url && URI(url).path.split('/').last.split('_')[1]
          return [] unless pk&.match?(/\A\d+\z/)

          [{ 'pk' => pk, 'media_type' => Media::PHOTO, 'product_type' => 'avatar',
             'image_versions2' => { 'candidates' => [{ 'url' => url, 'width' => 1 }] } }]
        end

        private

        # `after` goes at the top level of the variables, not inside `data`, as
        # in #reels_page. The three `__relay_internal__pv__` flags carry the
        # values the web client sends: multi-caption carousels on, the
        # reels-reco debug overlay and short drama off.
        def grid_page(username, cursor, number)
          variables = {
            after: cursor, before: nil, last: nil, first: PAGE,
            data: { count: PAGE, include_reel_media_seen_timestamp: true, include_relationship_info: true,
                    latest_besties_reel_media: true, latest_reel_media: true },
            include_multi_captions: true, username: username.to_s,
            __relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider: true,
            __relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider: false,
            __relay_internal__pv__PolarisShortDramaEnabledrelayprovider: false
          }
          page = graphql(GRID_QUERY, variables, label: "grid page #{number}")
          page.dig('data', 'xdt_api__v1__feed__user_timeline_graphql_connection') || {}
        end

        # `after` sits beside `data`, not inside it. Inside, the endpoint
        # ignores it and answers every request with the first page, and the
        # cursor it returns still changes each time -- so a walk that trusted
        # `has_next_page` would request the same twelve reels for ever.
        def reels_page(user_id, cursor, number)
          variables = {
            data: { include_feed_video: true, page_size: PAGE, target_user_id: user_id.to_s },
            user_id: user_id.to_s,
            __relay_internal__pv__PolarisShortDramaEnabledrelayprovider: false
          }
          variables[:after] = cursor if cursor
          page = graphql(REELS_QUERY, variables, label: "reels page #{number}")
          page.dig('data', 'fetch__XDTUserDict', 'clips_connection') || {}
        end

        # The site sends a dozen underscore-prefixed fields with every GraphQL
        # call; these are the ones the endpoint rejects the request without.
        def graphql(query, variables, label:)
          @client.post(
            GRAPHQL_URL,
            { av: '0', __d: 'www', __user: '0', __a: '1', dpr: '2',
              fb_dtsg: @tokens.fb_dtsg, doc_id: query[:doc_id], variables: JSON.generate(variables) },
            extra: { 'x-fb-friendly-name' => query[:name] },
            label:
          )
        end

        # The query answers no reels without `initial_reel_id`, and no items
        # without the provider flag; both come back as missing_required_variable_value.
        def reels_media(reel_ids)
          variables = {
            first: reel_ids.size, initial_reel_id: reel_ids.first, reel_ids:,
            __relay_internal__pv__PolarisCommunityNoteStoriesLabelEnabledrelayprovider: true
          }
          page = graphql(REELS_MEDIA_QUERY, variables, label: "reels media #{reel_ids.first}")
          edges = page.dig('data', 'xdt_api__v1__feed__reels_media__connection', 'edges')
          Array(edges).filter_map { it['node'] }
        end

        def exhausted?(rows, since)
          return false unless since && rows.any?

          Time.at(rows.last['taken_at'].to_i) < since
        end
      end
    end
  end
end
