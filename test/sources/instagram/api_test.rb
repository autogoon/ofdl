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

      # Answers the highlights tray with the collections given, each dated by
      # its newest story, and records which collections were then asked for.
      class FakeTrayClient
        attr_reader :asked

        def initialize(tray) = (@tray = tray) && @asked = []

        def get(path, params = {})
          return { 'tray' => @tray.map { |id, at| { 'id' => id, 'latest_reel_media' => at } } } if path.include?('tray')

          @asked << params[:reel_ids]
          { 'reels' => { params[:reel_ids] => { 'items' => [{ 'pk' => params[:reel_ids] }] } } }
        end
      end

      def tray_api(tray)
        client = FakeTrayClient.new(tray)
        [Instagram::Api.new(client:, tokens: FakeTokens.new), client]
      end

      def test_a_collection_with_nothing_newer_than_since_costs_no_request
        api, client = tray_api([['a', 1_760_000_000], ['b', 1_700_000_000], ['c', 1_770_000_000]])

        api.highlights(7, since: Time.at(1_750_000_000)).to_a

        assert_equal(%w[a c], client.asked)
      end

      def test_every_collection_is_asked_for_without_a_date
        api, client = tray_api([['a', 1_760_000_000], ['b', 1_700_000_000]])

        api.highlights(7).to_a

        assert_equal(%w[a b], client.asked)
      end
    end
  end
end
