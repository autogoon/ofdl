# frozen_string_literal: true

require_relative '../../test_helper'

module OFDL
  module Sources
    class InstagramApiTest < TestCase
      # Answers each POST with the next canned page and records the label the
      # request was logged under.
      class FakeClient
        attr_reader :labels, :forms

        def initialize(pages)
          @pages = pages
          @labels = []
          @forms = []
        end

        def post(_url, form, extra: {}, label: nil)
          @labels << label
          @forms << form
          raise ApiError, 'ran past the canned pages' if @pages.empty?

          { 'data' => { 'fetch__XDTUserDict' => { 'clips_connection' => @pages.shift } } }
        end
      end

      class FakeTokens
        def fb_dtsg = 'token'
      end

      def page(pks, has_next: false, cursor: 'next')
        { 'edges' => pks.map { { 'node' => { 'media' => { 'pk' => it } } } },
          'page_info' => { 'has_next_page' => has_next, 'end_cursor' => cursor } }
      end

      def api_over(pages)
        client = FakeClient.new(pages)
        [Instagram::Api.new(client:, tokens: FakeTokens.new), client]
      end

      def test_a_single_page_is_walked
        api, = api_over([page(%w[10 20])])

        assert_equal(%w[10 20], api.reels(7).map { it['pk'] })
      end

      # `after` sits beside `data`, not inside it; see Api#reels_page for what
      # putting it inside does.
      def test_the_cursor_carries_to_the_next_page_beside_the_data
        api, client = api_over([page(%w[10], has_next: true, cursor: 'C1'), page(%w[20])])

        assert_equal(%w[10 20], api.reels(7).map { it['pk'] })

        first, last = client.forms.map { JSON.parse(it[:variables]) }

        assert_nil(first['after'])
        assert_equal('C1', last['after'])
        refute(last['data'].key?('after'), 'after must not be nested inside data')
      end

      # A cursor that stops advancing returns the same empty page for ever.
      # Without this the walk requests it until the run is killed.
      def test_an_empty_page_ends_the_walk_even_when_more_is_promised
        api, client = api_over([page(%w[10], has_next: true), page([], has_next: true),
                                page(%w[20], has_next: true)])

        assert_equal(%w[10], api.reels(7).map { it['pk'] })
        assert_equal(2, client.labels.size)
      end

      # A POST's path carries none of what was asked for, so the label is what
      # the request log has to show; see Client#post.
      def test_each_page_is_logged_under_its_own_number
        api, client = api_over([page(%w[10], has_next: true), page(%w[20])])
        api.reels(7).to_a

        assert_equal(['reels page 1', 'reels page 2'], client.labels)
      end

      def test_the_query_carries_the_page_token
        api, client = api_over([page(%w[10])])
        api.reels(7).to_a

        assert_equal('token', client.forms.first[:fb_dtsg])
        assert_equal(Instagram::Api::REELS_QUERY[:doc_id], client.forms.first[:doc_id])
      end

      # Answers each POST with the next canned grid connection.
      class FakeGridClient
        attr_reader :forms, :labels

        def initialize(pages)
          @pages = pages
          @forms = []
          @labels = []
        end

        def post(_url, form, extra: {}, label: nil)
          @forms << form
          @labels << label
          raise ApiError, 'ran past the canned pages' if @pages.empty?

          { 'data' => { 'xdt_api__v1__feed__user_timeline_graphql_connection' => @pages.shift } }
        end
      end

      def grid(pks, has_next: false, cursor: 'next', taken_at: 1_768_000_000)
        { 'edges' => pks.map { { 'node' => { 'pk' => it, 'taken_at' => taken_at } } },
          'page_info' => { 'has_next_page' => has_next, 'end_cursor' => cursor } }
      end

      def grid_api(pages)
        client = FakeGridClient.new(pages)
        [Instagram::Api.new(client:, tokens: FakeTokens.new), client]
      end

      # The grid is GraphQL, and its rows are the edges' nodes; see
      # Api::GRID_QUERY.
      def test_the_grid_yields_the_node_of_each_edge
        api, = grid_api([grid(%w[10 20])])

        assert_equal(%w[10 20], api.timeline('creator').map { it['pk'] })
      end

      def test_the_grid_query_names_the_creator_and_carries_the_cursor
        api, client = grid_api([grid(%w[10], has_next: true, cursor: 'C1'), grid(%w[20])])
        api.timeline('creator').to_a

        first, last = client.forms.map { JSON.parse(it[:variables]) }

        assert_equal('creator', first['username'])
        assert_nil(first['after'])
        assert_equal('C1', last['after'])
        refute(last['data'].key?('after'), 'after must not be nested inside data')
      end

      # Newest first, so a page whose oldest row precedes `since` is the last
      # one worth asking for.
      def test_the_grid_walk_stops_at_a_page_older_than_since
        api, client = grid_api([grid(%w[10], has_next: true, taken_at: 1_700_000_000)])

        assert_equal(%w[10], api.timeline('creator', since: Time.at(1_760_000_000)).map { it['pk'] })
        assert_equal(1, client.forms.size)
      end

      # One media, keyed by shortcode; see Api::POST_QUERY.
      class FakePostClient
        attr_reader :forms

        def initialize(item)
          @item = item
          @forms = []
        end

        def post(_url, form, extra: {}, label: nil)
          @forms << form
          { 'data' => { 'xdt_api__v1__media__shortcode__web_info' => { 'items' => [@item].compact } } }
        end
      end

      def test_one_media_is_read_by_shortcode
        client = FakePostClient.new({ 'pk' => '10', 'taken_at' => 1_768_000_000 })
        api = Instagram::Api.new(client:, tokens: FakeTokens.new)

        assert_equal('10', api.media('SHORT')['pk'])
        assert_equal('SHORT', JSON.parse(client.forms.first[:variables])['shortcode'])
      end

      # The query answers an empty list and an error without them; see
      # Api::POST_QUERY.
      def test_the_media_query_carries_the_two_flags_it_needs
        client = FakePostClient.new(nil)
        Instagram::Api.new(client:, tokens: FakeTokens.new).media('SHORT')

        variables = JSON.parse(client.forms.first[:variables])

        assert(variables['__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider'])
        assert_equal(false, variables['__relay_internal__pv__PolarisShortDramaEnabledrelayprovider'])
      end

      # Answers the profile query with the user row given; see Api::PROFILE_QUERY.
      class FakeProfileClient
        attr_reader :forms

        def initialize(user)
          @user = user
          @forms = []
        end

        def post(_url, form, extra: {}, label: nil)
          @forms << form
          { 'data' => { 'user' => @user } }
        end
      end

      PIC = 'https://cdn.example.com/v/t51.2885-19/111111111_22222222222222222_3333333333333333333_n.jpg'

      def test_the_avatar_is_keyed_on_the_middle_number_of_its_filename
        client = FakeProfileClient.new({ 'hd_profile_pic_url_info' => { 'url' => "#{PIC}?stp=x" } })
        rows = Instagram::Api.new(client:, tokens: FakeTokens.new).avatar(7)

        assert_equal('22222222222222222', rows.first['pk'])
        assert_equal("#{PIC}?stp=x", rows.first.dig('image_versions2', 'candidates', 0, 'url'))
        assert_equal('7', JSON.parse(client.forms.first[:variables])['id'])
      end

      def test_no_avatar_without_a_picture_url
        client = FakeProfileClient.new({})

        assert_empty(Instagram::Api.new(client:, tokens: FakeTokens.new).avatar(7))
      end

      # Answers the tray query one page at a time, and `reels_media` with each
      # collection asked for, dated by its newest story.
      class FakeTrayClient
        attr_reader :asked, :forms

        def initialize(pages, dates)
          @pages = pages
          @dates = dates
          @asked = []
          @forms = []
        end

        def post(_url, form, extra: {}, label: nil)
          @forms << form
          ids, cursor = @pages.shift
          { 'data' => { 'highlights' => {
            'edges' => ids.map { { 'node' => { 'id' => it } } },
            'page_info' => { 'has_next_page' => !cursor.nil?, 'end_cursor' => cursor }
          } } }
        end

        def get(_path, params = {})
          @asked << params[:reel_ids]
          ids = params[:reel_ids].split(',')
          { 'reels' => ids.to_h { [it, { 'latest_reel_media' => @dates[it], 'items' => [{ 'pk' => it }] }] } }
        end
      end

      def tray_api(pages, dates)
        client = FakeTrayClient.new(pages, dates)
        [Instagram::Api.new(client:, tokens: FakeTokens.new), client]
      end

      def test_one_request_carries_every_collection_on_a_tray_page
        api, client = tray_api([[%w[a b c]]], {})

        assert_equal(%w[a b c], api.highlights(7).map { it['pk'] })
        assert_equal(['a,b,c'], client.asked)
      end

      def test_a_collection_with_nothing_newer_than_since_yields_nothing
        api, = tray_api([[%w[a b c]]], { 'a' => 1_760_000_000, 'b' => 1_700_000_000, 'c' => 1_770_000_000 })

        assert_equal(%w[a c], api.highlights(7, since: Time.at(1_750_000_000)).map { it['pk'] })
      end

      def test_the_tray_cursor_carries_to_the_next_page
        api, client = tray_api([[%w[a], 'next'], [%w[b]]], {})

        assert_equal(%w[a b], api.highlights(7).map { it['pk'] })
        assert_equal(%w[a b], client.asked)
        assert_equal('next', JSON.parse(client.forms.last[:variables])['after'])
      end

      def test_a_tray_page_fits_in_one_reels_media_request
        api, client = tray_api([[%w[a]]], {})
        api.highlights(7).to_a

        assert_equal(Instagram::Api::REELS_PER_REQUEST, JSON.parse(client.forms.first[:variables])['first'])
      end
    end
  end
end
