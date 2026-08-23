# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class TransportTest < TestCase
    def curl = Transport::CurlImpersonate.new(binary: 'curl-impersonate', target: 'chrome150')

    def installed? = curl.available?

    def test_response_reports_success_by_status
      assert_predicate(Transport::Response.new(status: 200, content_type: 'application/json', body: '{}'), :success?)
      refute_predicate(Transport::Response.new(status: 400, content_type: nil, body: ''), :success?)
    end

    # See CurlImpersonate#supports? for why this stays offline.
    def test_validates_targets_without_network
      skip('curl-impersonate not installed') unless installed?

      assert(curl.supports?('chrome150'))
      refute(curl.supports?('chrome999'))
    end

    def test_picks_the_newest_chrome_profile
      skip('curl-impersonate not installed') unless installed?

      transport = Transport::CurlImpersonate.newest_chrome(log: silent_log)
      targets = curl.chrome_targets

      assert_equal("chrome#{targets.max}", transport.target)
    end

    def test_a_missing_binary_explains_how_to_install_it
      error = assert_raises(ConfigError) do
        Transport::CurlImpersonate.newest_chrome(binary: 'curl-impersonate-nope', log: silent_log)
      end

      assert_match(/not found/, error.message)
      assert_match(/brew install curl-impersonate/, error.message)
    end
  end
end
