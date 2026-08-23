# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class SiteStateTest < TestCase
    # Stands in for Transport::CurlImpersonate.
    class FakeTransport
      attr_reader :calls

      def initialize(responses)
        @responses = responses
        @calls = []
      end

      def get(url, _headers)
        @calls << url
        response = @responses.shift or raise('ran out of canned responses')
        response.is_a?(Exception) ? raise(response) : response
      end
    end

    def ok(body, content_type = 'text/html')
      Transport::Response.new(status: 200, content_type:, body:)
    end

    def page(revision = '202608211829-e25f858429')
      %(<meta property=og:image content=https://static2.onlyfans.com/static/prod/f/#{revision}/images/of-logo-b.jpg>)
    end

    def build(responses, clock: -> { 0.0 })
      transport = FakeTransport.new(responses)
      [SiteState.new(transport:, auth_id: '12345', log: silent_log, clock:), transport]
    end

    # Why the revision is parsed rather than pinned: see the SiteState class
    # comment.
    def test_reads_the_revision_from_the_homepage
      state, transport = build([ok(page)])

      assert_equal('202608211829-e25f858429', state.revision)
      assert_equal(SiteState::HOME_URL, transport.calls.first)
    end

    def test_revision_is_fetched_once_per_run
      state, transport = build([ok(page)])
      3.times { state.revision }

      assert_equal(1, transport.calls.size)
    end

    def test_a_page_without_a_revision_is_an_error
      state, = build([ok('<html>nothing useful</html>')])

      assert_match(/no build revision/, assert_raises(ApiError) { state.revision }.message)
    end

    def test_fetches_the_hash_with_the_account_id
      state, transport = build([ok('HASHVALUE...', 'text/plain')])

      assert_equal('HASHVALUE...', state.content_hash)
      assert_equal("#{SiteState::HASH_URL}?u=12345", transport.calls.first)
    end

    def test_hash_is_cached_within_the_ttl
      now = 0.0
      state, transport = build([ok('first', 'text/plain'), ok('second', 'text/plain')], clock: -> { now })

      assert_equal('first', state.content_hash)
      now = SiteState::HASH_TTL_SECONDS - 1
      assert_equal('first', state.content_hash)
      assert_equal(1, transport.calls.size)
    end

    def test_hash_is_refetched_once_the_ttl_lapses
      now = 0.0
      state, transport = build([ok('first', 'text/plain'), ok('second', 'text/plain')], clock: -> { now })

      state.content_hash
      now = SiteState::HASH_TTL_SECONDS
      assert_equal('second', state.content_hash)
      assert_equal(2, transport.calls.size)
    end

    # Why a failed hash is not fatal: see SiteState#fetch_hash.
    def test_a_failed_hash_is_survivable
      state, = build([ok(page), Transport::Response.new(status: 503, content_type: nil, body: '')])

      assert_equal({ 'x-of-rev' => '202608211829-e25f858429' }, state.headers)
    end

    def test_headers_carry_both_when_available
      state, = build([ok(page), ok('HASHVALUE', 'text/plain')])

      assert_equal({ 'x-of-rev' => '202608211829-e25f858429', 'x-hash' => 'HASHVALUE' }, state.headers)
    end

    def test_neither_request_sends_cookies
      state, transport = build([ok(page), ok('HASHVALUE', 'text/plain')])
      state.headers

      assert_equal(2, transport.calls.size)
      refute_includes(transport.calls.join, 'cookie')
    end
  end
end
