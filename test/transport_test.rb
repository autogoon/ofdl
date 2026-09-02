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

    # A transfer that connects and then goes quiet never raises on its own, so
    # curl is told to give up on one; see CurlImpersonate::STALL_SECONDS.
    def test_a_download_gives_curl_a_no_activity_timeout
      argv = curl.send(:command, 'https://cdn.example.com/a.mp4', {},
                       Transport::CurlImpersonate::DOWNLOAD_MAX_TIME)

      assert_includes(argv, '--speed-time')
      assert_includes(argv, '--speed-limit')
      assert_equal(Transport::CurlImpersonate::STALL_SECONDS.to_s, argv[argv.index('--speed-time') + 1])
    end

    # curl exits 28 when it gives up on a stalled or over-long transfer. The
    # bytes stopped arriving; asking again is exactly the right response, so
    # this one is retryable where other curl failures are not.
    def test_a_stalled_download_is_retryable
      transport = curl
      transport.define_singleton_method(:run) do |_argv|
        [+'', +'Operation too slow', Struct.new(:success?, :exitstatus).new(false, 28)]
      end

      error = assert_raises(DownloadError) do
        transport.download('https://cdn.example.com/a.mp4', Pathname('/tmp/ofdl-nope'))
      end

      assert_predicate(error, :retryable?)
    end

    def test_other_curl_failures_are_not_retryable
      transport = curl
      transport.define_singleton_method(:run) do |_argv|
        [+'', +'could not resolve host', Struct.new(:success?, :exitstatus).new(false, 6)]
      end

      error = assert_raises(DownloadError) do
        transport.download('https://cdn.example.com/a.mp4', Pathname('/tmp/ofdl-nope'))
      end

      refute_predicate(error, :retryable?)
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
