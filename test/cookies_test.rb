# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class CookiesTest < TestCase
    KEY = OpenSSL::PKCS5.pbkdf2_hmac_sha1('password', Cookies::SALT, Cookies::ITERATIONS, Cookies::KEY_LENGTH)

    def encrypt(plaintext, version: 'v10')
      cipher = OpenSSL::Cipher.new('aes-128-cbc')
      cipher.encrypt
      cipher.key = KEY
      cipher.iv = Cookies::IV
      "#{version}#{cipher.update(plaintext) + cipher.final}"
    end

    def decrypt(blob) = Cookies.send(:decrypt, blob, KEY)

    def test_round_trips_a_cookie_value
      assert_equal('abc123', decrypt(encrypt('abc123')))
    end

    # see Cookies.strip_domain_hash
    def test_strips_the_domain_hash_prefix
      digest = OpenSSL::Digest.digest('SHA256', 'onlyfans.com')

      assert_equal('sess-token', decrypt(encrypt("#{digest}sess-token")))
    end

    def test_leaves_values_that_merely_look_long_alone
      value = 'a' * 64

      assert_equal(value, decrypt(encrypt(value)))
    end

    # see Cookies.printable?
    def test_an_empty_cookie_decrypts_to_an_empty_string
      digest = OpenSSL::Digest.digest('SHA256', 'onlyfans.com')

      assert_equal('', decrypt(encrypt(digest)))
    end

    def test_an_empty_cookie_never_leaks_the_domain_hash
      digest = OpenSSL::Digest.digest('SHA256', 'onlyfans.com')
      value = decrypt(encrypt(digest))

      assert_predicate(value, :ascii_only?)
      refute_includes(value, digest.byteslice(0, 4))
    end

    def test_rejects_unknown_encryption_versions
      error = assert_raises(CookieError) { decrypt(encrypt('x', version: 'v99')) }

      assert_match(/unsupported cookie encryption/, error.message)
    end

    def test_jar_builds_the_header_in_a_stable_order
      jar = Cookies::Jar.new(values: { 'sess' => 's', 'auth_id' => '1', 'fp' => 'f', 'csrf' => 'c' })

      assert_equal('csrf=c; fp=f; sess=s; auth_id=1', jar.header)
      assert_equal('1', jar.auth_id)
      assert_equal('f', jar.xbc)
      assert_predicate(jar, :complete?)
    end

    # see Cookies::Jar#header
    def test_jar_includes_every_cookie_after_the_required_ones
      jar = Cookies::Jar.new(values: {
                               'sess' => 's', 'auth_id' => '1', 'fp' => 'f', 'csrf' => 'c',
                               'cf_clearance' => 'cf', '__cf_bm' => 'bm', 'lang' => 'en'
                             })

      assert_equal('csrf=c; fp=f; sess=s; auth_id=1; __cf_bm=bm; cf_clearance=cf; lang=en', jar.header)
    end

    def test_jar_skips_empty_values
      jar = Cookies::Jar.new(values: { 'sess' => 's', 'auth_id' => '1', 'fp' => 'f', 'st' => '' })

      refute_includes(jar.header, 'st=')
    end

    # see Cookies::Jar#header
    def test_jar_drops_values_that_are_not_header_safe
      jar = Cookies::Jar.new(values: {
                               'sess' => 's', 'auth_id' => '1', 'fp' => 'f',
                               'ref_src' => 255.chr * 8
                             })

      assert_predicate(jar.header, :ascii_only?)
      refute_includes(jar.header, 'ref_src')
      assert_equal(['ref_src'], jar.unsafe)
    end

    def test_a_clean_jar_reports_nothing_unsafe
      jar = Cookies::Jar.new(values: { 'sess' => 's', 'auth_id' => '1', 'fp' => 'f' })

      assert_empty(jar.unsafe)
    end

    def test_jar_reports_what_is_missing
      jar = Cookies::Jar.new(values: { 'sess' => 's' })

      refute_predicate(jar, :complete?)
      assert_includes(jar.missing, 'auth_id')
    end
  end
end
