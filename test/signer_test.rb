# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class SignerTest < TestCase
    def signer = Signer.new(rules: sample_rules, user_id: '42', xbc: 'fingerprint')

    def test_matches_the_reference_algorithm
      time = Time.at(1_700_000_000)
      path = '/api2/v2/users/me?u=42'

      headers = signer.headers_for(path, now: time)

      expected_time = '1700000000000'
      digest = Digest::SHA1.hexdigest(['STATIC', expected_time, path, '42'].join("\n"))
      checksum = [0, 5, 9].sum { |i| digest[i].ord } + 1000

      assert_equal(expected_time, headers['time'])
      assert_equal(['ABC', digest, checksum.to_s(16), 'XYZ'].join(':'), headers['sign'])
    end

    def test_carries_identity_headers
      headers = signer.headers_for('/api2/v2/users/me?u=42')

      assert_equal(Signer::APP_TOKEN, headers['app-token'])
      assert_equal('42', headers['user-id'])
      assert_equal('fingerprint', headers['x-bc'])
    end

    def test_query_string_is_part_of_the_signature
      now = Time.at(1_700_000_000)
      a = signer.headers_for('/api2/v2/users/1/posts?limit=50&u=42', now:)
      b = signer.headers_for('/api2/v2/users/1/posts?limit=10&u=42', now:)

      refute_equal(a['sign'], b['sign'])
    end

    def test_negative_checksum_constant_formats_like_javascript
      rules = sample_rules.with(checksum_constant: -100_000)
      headers = Signer.new(rules:, user_id: '1', xbc: 'x').headers_for('/api2/v2/users/me?u=1', now: Time.at(0))

      assert_includes(headers['sign'], ':-')
    end
  end
end
