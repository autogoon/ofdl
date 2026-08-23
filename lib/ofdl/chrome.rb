# frozen_string_literal: true

require 'open3'

module OFDL
  # Locates the installed Chrome and reports its major version.
  #
  # The only thing derived from it is the User-Agent. curl-impersonate supplies
  # the TLS fingerprint and every other browser header.
  #
  # The two are allowed to disagree. curl-impersonate trails Chrome's release
  # cadence, so its newest profile is often a major behind what is installed;
  # the fingerprint comes from that newest profile, while the User-Agent reports
  # the installed Chrome, whose profile the session cookies come from.
  # Cloudflare fingerprints TLS and header shape; OnlyFans, if it checks
  # anything, checks the User-Agent.
  module Chrome
    BUNDLES = ['/Applications/Google Chrome.app', '~/Applications/Google Chrome.app'].freeze

    # Chrome's UA is reduced: platform frozen at 10_15_7 even on Apple silicon,
    # and minor/build/patch always reported as 0.0.0.
    UA_TEMPLATE = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' \
                  '(KHTML, like Gecko) Chrome/%<major>s.0.0.0 Safari/537.36'

    class << self
      def installed? = !bundle.nil?

      def version = @version ||= bundle && read_version(bundle)

      def major_version
        @major_version ||= version&.[](/\A(\d+)\./, 1)&.to_i
      end

      def user_agent
        major = major_version or raise ConfigError, 'Chrome is not installed in /Applications or ~/Applications'

        format(UA_TEMPLATE, major:)
      end

      def bundle = @bundle ||= BUNDLES.map { Pathname(it).expand_path }.find(&:directory?)

      def reset!
        @bundle = @version = @major_version = nil
      end

      private

      def read_version(bundle)
        out, status = Open3.capture2e(
          '/usr/bin/plutil', '-extract', 'CFBundleShortVersionString', 'raw',
          bundle.join('Contents', 'Info.plist').to_s
        )
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
