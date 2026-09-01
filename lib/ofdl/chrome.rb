# frozen_string_literal: true

require 'open3'

module OFDL
  # Locates the installed Chrome and reports its major version.
  #
  # The only thing derived from it is the User-Agent. curl-impersonate supplies
  # the TLS fingerprint and every other browser header.
  #
  # The two are allowed to disagree. curl-impersonate trails Chrome's release
  # cadence, so curl-impersonate's newest profile is often a major behind what
  # is running; the fingerprint comes from that newest profile, while the
  # User-Agent reports the Chrome that made the session cookies. Cloudflare
  # fingerprints TLS and header shape; OnlyFans, if it checks anything, checks
  # the User-Agent.
  #
  # The version is the one that last ran, not the one installed. Chrome stages
  # an update by replacing the bundle while the old build keeps running, so
  # Info.plist can report a major version under which no session was created. A
  # User-Agent built from that major contradicts the cookies in the same
  # request.
  module Chrome
    BUNDLES = ['/Applications/Google Chrome.app', '~/Applications/Google Chrome.app'].freeze

    # Written by Chrome each time it starts. Shared with Cookies::PROFILE_ROOT,
    # which reads the jar the same Chrome wrote.
    LAST_VERSION = 'Last Version'

    # Chrome's UA is reduced: platform frozen at 10_15_7 even on Apple silicon,
    # and minor/build/patch always reported as 0.0.0.
    UA_TEMPLATE = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' \
                  '(KHTML, like Gecko) Chrome/%<major>s.0.0.0 Safari/537.36'

    class << self
      def installed? = !bundle.nil?

      def version = @version ||= last_run_version || installed_version

      def installed_version = bundle && read_version(bundle)

      def profile_root = Pathname(Cookies::PROFILE_ROOT).expand_path

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

      def last_run_version(root = profile_root)
        path = root.join(LAST_VERSION)
        return nil unless path.file?

        version = path.read.strip
        version.match?(/\A\d+\./) ? version : nil
      rescue SystemCallError
        nil
      end

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
