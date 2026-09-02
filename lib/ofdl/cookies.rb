# frozen_string_literal: true

require 'fileutils'
require 'openssl'
require 'tmpdir'

module OFDL
  # Reads one site's cookies from the local Chrome profile.
  #
  # Chrome keeps cookies in a SQLite file with each value encrypted under a key
  # stored in the login Keychain. We copy the file (Chrome holds a write lock on
  # the original), read it with the system `sqlite3` binary, and decrypt
  # in-process. No cookie is written anywhere, and a jar is sent only to the
  # host it was read for.
  module Cookies
    # Which cookies one site needs, and in what order.
    #
    # `host` is the domain the cookies are read for and sent to. `lead` is the
    # cookies that domain's browser client sends first; putting them at the
    # front of the header keeps the header identical from run to run.
    # `required` is the smaller set a run cannot start without: Cookies.load
    # checks for them and raises naming the absent ones, so a missing sign-in
    # is reported before the first request rather than as its failure.
    #
    # Sources::OnlyFans::COOKIES gives onlyfans.com's host, lead and required.
    Site = Data.define(:host, :lead, :required)

    KEYCHAIN_SERVICE = 'Chrome Safe Storage'
    KEYCHAIN_ACCOUNT = 'Chrome'
    PROFILE_ROOT = '~/Library/Application Support/Google/Chrome'

    SQLITE_CANDIDATES = ['/usr/bin/sqlite3', 'sqlite3'].freeze

    # Chrome's fixed KDF parameters for the macOS keychain-derived key.
    SALT = 'saltysalt'
    ITERATIONS = 1003
    KEY_LENGTH = 16
    IV = (' ' * 16).freeze

    Jar = Data.define(:values, :site) do
      def [](name) = values.fetch(name, '')

      # Chrome sends the whole jar, and that includes Cloudflare's
      # bot-management sets (`cf_clearance`, `__cf_bm`) -- omitting those makes
      # the request look like a bot to the edge, which never reaches the
      # application at all.
      #
      # One bad byte invalidates the entire Cookie header, and the request is
      # then refused as malformed with no body -- so a decryption edge case
      # must cost one cookie, never the whole run.
      def header
        ordered = site.lead + (values.keys - site.lead).sort
        ordered.filter_map { |n| "#{n}=#{values[n]}" if present?(n) && header_safe?(values[n]) }.join('; ')
      end

      def unsafe = values.reject { |_, v| header_safe?(v) }.keys

      def header_safe?(value) = value.to_s.dup.force_encoding(Encoding::BINARY).match?(/\A[\x20-\x7e]*\z/n)

      def complete? = missing.empty?

      def missing = site.required.reject { present?(it) }

      def present?(name) = !values[name].to_s.empty?
    end

    class << self
      def load(site:, profile: 'Default')
        jar = Jar.new(values: read_values(profile:, host: site.host), site:)
        unless jar.complete?
          raise CookieError, <<~MSG.strip
            incomplete #{site.host} cookies in Chrome profile #{profile.inspect} (missing: #{jar.missing.join(', ')})
            Sign in at https://#{site.host} in that profile, then retry.
          MSG
        end

        jar
      end

      def profile_dir(profile:) = Pathname(PROFILE_ROOT).expand_path.join(profile)

      private

      def read_values(profile:, host:)
        dir = profile_dir(profile:)
        jar_path = [dir.join('Network', 'Cookies'), dir.join('Cookies')].find(&:file?)
        raise CookieError, "no cookie store under #{dir}" unless jar_path

        key = derive_key

        Dir.mktmpdir('ofdl-cookies') do |tmp|
          copy = Pathname(tmp).join('Cookies')
          FileUtils.cp(jar_path, copy)
          rows(copy, host).to_h do |name, plain_hex, cipher_hex|
            [name, cipher_hex.empty? ? unhex(plain_hex) : decrypt(unhex(cipher_hex), key)]
          end
        end
      end

      # Everything is selected as hex so the `|` separator can never appear
      # inside a field.
      def rows(path, host)
        sql = 'SELECT name, hex(value), hex(encrypted_value) FROM cookies ' \
              "WHERE host_key LIKE '%#{host}';"
        out = run(sqlite_binary, path.to_s, sql, error: "could not read #{path}")
        out.each_line.filter_map do |line|
          name, plain_hex, cipher_hex = line.chomp.split('|', 3)
          next unless name

          [name, plain_hex.to_s, cipher_hex.to_s]
        end
      end

      def sqlite_binary
        @sqlite_binary ||= SQLITE_CANDIDATES.find do |c|
          system('command', '-v', c, out: File::NULL, err: File::NULL)
        end ||
                           raise(CookieError, "no sqlite3 binary found (looked for #{SQLITE_CANDIDATES.join(', ')})")
      end

      def derive_key
        password = run(
          'security', 'find-generic-password', '-w', '-s', KEYCHAIN_SERVICE, '-a', KEYCHAIN_ACCOUNT,
          error: "could not read #{KEYCHAIN_SERVICE.inspect} from the Keychain (deny/cancel at the prompt?)"
        ).chomp
        raise CookieError, "empty #{KEYCHAIN_SERVICE.inspect} keychain entry" if password.empty?

        OpenSSL::PKCS5.pbkdf2_hmac_sha1(password, SALT, ITERATIONS, KEY_LENGTH)
      end

      def decrypt(blob, key)
        version = blob.byteslice(0, 3)
        raise CookieError, "unsupported cookie encryption #{version.inspect}" unless %w[v10 v11].include?(version)

        cipher = OpenSSL::Cipher.new('aes-128-cbc')
        cipher.decrypt
        cipher.key = key
        cipher.iv = IV
        cipher.padding = 0
        plain = cipher.update(blob.byteslice(3..)) + cipher.final
        strip_domain_hash(strip_pkcs7(plain))
      rescue OpenSSL::Cipher::CipherError => e
        raise CookieError, "cookie decryption failed: #{e.message}"
      end

      def strip_pkcs7(plain)
        pad = plain.getbyte(plain.bytesize - 1).to_i
        return plain unless pad.between?(1, 16) && pad <= plain.bytesize

        plain.byteslice(0, plain.bytesize - pad)
      end

      # Recent Chrome prepends a 32-byte SHA-256 of the host to the plaintext.
      # Detect it rather than version-sniffing: a cookie value is printable
      # ASCII, a hash is not.
      def strip_domain_hash(plain)
        value = plain.dup.force_encoding(Encoding::BINARY)
        return value.force_encoding(Encoding::UTF_8) if printable?(value)

        candidate = value.byteslice(32..).to_s
        printable?(candidate) ? candidate.force_encoding(Encoding::UTF_8) : value.force_encoding(Encoding::UTF_8)
      end

      # The empty string is printable. An empty cookie decrypts to the 32-byte
      # domain hash and nothing else, so treating "" as unprintable would
      # return that hash as the cookie's value.
      def printable?(string) = string.match?(/\A[\x20-\x7e]*\z/n)

      def unhex(hex) = hex.to_s.empty? ? '' : [hex].pack('H*')

      def run(*command, error:)
        require 'open3'
        out, err, status = Open3.capture3(*command)
        raise CookieError, "#{error}: #{err.strip}" unless status.success?

        out
      rescue Errno::ENOENT
        raise CookieError, "#{command.first} not found on PATH"
      end
    end
  end
end
