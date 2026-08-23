# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  # Drives Client's retry/refresh logic without a socket by standing in for the
  # curl transport.
  class FakeTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def get(url, headers)
      @calls << { url:, headers: }
      @responses.shift or raise('ran out of canned responses')
    end

    def paths = @calls.map { URI(it[:url]).then { |u| u.query ? "#{u.path}?#{u.query}" : u.path } }

    def signatures = @calls.map { it[:headers]['sign'] }
  end

  class ClientTest < TestCase
    def response(status, body = '{}')
      Transport::Response.new(status:, content_type: 'application/json', body:)
    end

    def jar = Cookies::Jar.new(values: { 'sess' => 's', 'auth_id' => '42', 'fp' => 'f' })

    def signer_for(param) = Signer.new(rules: sample_rules.with(static_param: param), user_id: '42', xbc: 'f')

    # Stands in for SiteState without any fetching.
    StubSiteState = Struct.new(:headers)

    def build(responses, refresh_signer: nil, site_state: nil)
      transport = FakeTransport.new(responses)
      client = Client.new(
        jar:, signer: signer_for('OLD'), transport:, site_state:,
        rate_limiter: RateLimiter.new(1000), log: silent_log, refresh_signer:
      )
      [client, transport]
    end

    # see Client#headers
    def test_carries_the_site_state_headers
      stub = StubSiteState.new({ 'x-of-rev' => '202608211829-e25f858429', 'x-hash' => 'HASHVALUE' })
      client, transport = build([response(200)], site_state: stub)
      client.get('/users/me')
      headers = transport.calls.first[:headers]

      assert_equal('202608211829-e25f858429', headers['x-of-rev'])
      assert_equal('HASHVALUE', headers['x-hash'])
    end

    def test_works_without_site_state
      client, transport = build([response(200)])
      client.get('/users/me')

      refute(transport.calls.first[:headers].key?('x-of-rev'))
    end

    def test_returns_parsed_json
      client, = build([response(200, '{"id":1}')])

      assert_equal({ 'id' => 1 }, client.get('/users/me'))
    end

    # see Client#handle
    def test_surfaces_the_error_body
      client, = build([response(400, '{"error":{"code":0,"message":"Please refresh the page"}}')])

      error = assert_raises(ApiError) { client.get('/users/me') }

      assert_match(/Please refresh the page/, error.message)
    end

    def test_keeps_the_error_body_after_a_failed_refresh
      client, = build([response(400, '{"error":{"message":"bad sign"}}'),
                       response(400, '{"error":{"message":"bad sign"}}')],
                      refresh_signer: -> { signer_for('NEW') })

      error = assert_raises(ApiError) { client.get('/users/me') }

      assert_match(/bad sign/, error.message)
      assert_match(/still rejected after refreshing/, error.message)
    end

    # These three pin the signed string; see Client#build_uri.
    def test_signs_the_bare_path_when_there_are_no_params
      client, transport = build([response(200)])
      client.get('/users/me')

      assert_equal('/api2/v2/users/me', transport.paths.first)
    end

    def test_signs_the_path_with_its_query
      client, transport = build([response(200)])
      client.get('/users/1/posts', { limit: 50, order: 'publish_date_desc' })

      assert_equal('/api2/v2/users/1/posts?limit=50&order=publish_date_desc', transport.paths.first)
    end

    def test_never_sends_the_media_adapter_auth_parameter
      client, transport = build([response(200)])
      client.get('/subscriptions/subscribes', { offset: 0, type: 'all' })

      refute_includes(transport.paths.first, 'u=')
    end

    # see Client::XHR_HEADERS
    def test_corrects_the_fetch_metadata_to_an_xhr
      client, transport = build([response(200)])
      client.get('/users/me')
      headers = transport.calls.first[:headers]

      assert_equal('cors', headers['sec-fetch-mode'])
      assert_equal('empty', headers['sec-fetch-dest'])
      assert_equal('same-origin', headers['sec-fetch-site'])
      assert_equal('application/json, text/plain, */*', headers['accept'])
    end

    # see Client::XHR_HEADERS
    def test_removes_the_document_navigation_header
      client, transport = build([response(200)])
      client.get('/users/me')

      assert_equal('', transport.calls.first[:headers]['upgrade-insecure-requests'])
    end

    def test_reports_the_installed_chrome_in_the_user_agent
      skip('Chrome not installed') unless Chrome.installed?

      client, transport = build([response(200)])
      client.get('/users/me')

      assert_equal(Chrome.user_agent, transport.calls.first[:headers]['user-agent'])
    end

    def test_refetches_rules_once_when_the_signature_is_rejected
      refreshes = 0
      client, transport = build([response(400), response(200, '{"ok":true}')],
                                refresh_signer: lambda {
                                  refreshes += 1
                                  signer_for('NEW')
                                })

      assert_equal({ 'ok' => true }, client.get('/users/me'))
      assert_equal(1, refreshes)
      assert_equal(2, transport.calls.size)
    end

    def test_a_new_signer_actually_signs_the_retry
      client, transport = build([response(400), response(200)], refresh_signer: -> { signer_for('NEW') })
      client.get('/users/me')

      first, second = transport.signatures

      refute_equal(first, second, 'retry reused the rejected signature')
    end

    def test_gives_up_after_one_refresh
      refreshes = 0
      client, = build([response(401), response(401)],
                      refresh_signer: lambda {
                        refreshes += 1
                        signer_for('NEW')
                      })

      error = assert_raises(ApiError) { client.get('/users/me') }

      assert_equal(1, refreshes)
      assert_match(/still rejected after refreshing/, error.message)
      assert_match(/HTTP 401/, error.message)
    end

    def test_refresh_happens_at_most_once_across_calls
      refreshes = 0
      client, = build([response(403), response(200), response(403), response(200)],
                      refresh_signer: lambda {
                        refreshes += 1
                        signer_for('NEW')
                      })

      client.get('/users/me')
      assert_raises(ApiError) { client.get('/users/me') }

      assert_equal(1, refreshes)
    end

    def test_does_not_refresh_on_a_server_error
      refreshes = 0
      client, = build([response(500), response(200)], refresh_signer: lambda {
        refreshes += 1
        signer_for('NEW')
      })
      client.get('/users/me')

      assert_equal(0, refreshes)
    end
  end
end
