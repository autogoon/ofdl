# frozen_string_literal: true

require 'open3'
require 'tempfile'

module OFDL
  # HTTP transport, via curl-impersonate.
  #
  # Ruby's Net::HTTP cannot get past Cloudflare here. It is HTTP/1.1 with a
  # Title-Cased header order no browser produces, an "Accept-Encoding:
  # gzip;q=1.0,deflate;q=0.6,identity;q=0.3" that is a Ruby signature, and an
  # OpenSSL TLS fingerprint that is not Chrome's. Correct request signatures
  # still come back HTTP 400 with an empty body -- a rejection at the edge,
  # before OnlyFans sees the request.
  #
  # curl-impersonate reproduces Chrome's TLS stack, h2 settings, header order
  # and casing. Callers add the OnlyFans-specific headers and the XHR
  # corrections in Client::XHR_HEADERS, and leave curl to supply the rest of
  # what a browser sends: accept-encoding, accept-language, sec-ch-ua*.
  # Overriding those would make the request internally inconsistent, which
  # fingerprints worse than not sending them at all.
  module Transport
    Response = Data.define(:status, :content_type, :body) do
      def success? = (200..299).cover?(status)
    end

    # The only transport. Every request goes through the binary rather than a
    # Ruby HTTP stack, so the TLS fingerprint and header shape are Chrome's.
    class CurlImpersonate
      DEFAULT_BINARY = 'curl-impersonate'
      # curl exits 43 with "Unknown impersonation target" for a profile it does
      # not have. --show-error is required, or --silent swallows the message.
      UNKNOWN_TARGET_EXIT = 43
      CONNECT_TIMEOUT = 15
      MAX_TIME = 60
      DOWNLOAD_MAX_TIME = 3600

      attr_reader :binary, :target

      def initialize(binary:, target:)
        @binary = binary
        @target = target
      end

      # Always the newest Chrome profile this curl-impersonate offers.
      #
      # The profile supplies the TLS and h2 fingerprint, and the newest is the
      # closest to a current browser. It is not required to match the installed
      # Chrome -- the User-Agent carries that, separately.
      def self.newest_chrome(log:, binary: DEFAULT_BINARY)
        probe = new(binary:, target: 'chrome0')
        raise ConfigError, missing_binary(binary) unless probe.available?

        targets = probe.chrome_targets
        raise ConfigError, no_targets(binary) if targets.empty?

        newest = targets.max
        log.debug("curl-impersonate: chrome#{newest} (of #{targets.size} chrome profiles)")
        new(binary:, target: "chrome#{newest}")
      end

      def self.missing_binary(binary)
        "#{binary} not found. Install curl-impersonate (brew install curl-impersonate), " \
          'or set "curl_impersonate" in the config to its path.'
      end

      def self.no_targets(binary)
        "#{binary} reports no chrome impersonation profiles -- is it really curl-impersonate?"
      end

      def available?
        _, status = Open3.capture2e(@binary, '--version')
        status.success?
      rescue Errno::ENOENT
        false
      end

      def version
        out, status = Open3.capture2e(@binary, '--version')
        status.success? ? out.lines.first.to_s.strip : nil
      rescue Errno::ENOENT
        nil
      end

      def describe = "#{@binary} --impersonate #{@target}"

      # Checked against a file:// URL, so this costs no network request.
      def supports?(target)
        _, err, status = Open3.capture3(
          @binary, '--impersonate', target, '--silent', '--show-error', 'file:///dev/null'
        )
        return false if status.exitstatus == UNKNOWN_TARGET_EXIT

        !err.include?('Unknown impersonation target')
      rescue Errno::ENOENT
        false
      end

      # Enumerated from the wrapper scripts shipped beside the binary, then
      # confirmed against the binary itself.
      def chrome_targets
        @chrome_targets ||= wrapper_majors.select { supports?("chrome#{it}") }.sort
      end

      def get(url, headers)
        Tempfile.create('ofdl-body') do |body|
          out, err, status = run(command(url, headers, body.path, MAX_TIME))
          raise ApiError, "#{@binary} failed (#{status.exitstatus}): #{err.strip}" unless status.success?

          code, content_type = out.strip.split(' ', 2)
          Response.new(status: code.to_i, content_type:, body: File.read(body.path))
        end
      end

      # Writes straight to `destination`. Returns the HTTP status; the caller
      # decides what a non-200 means.
      #
      # `dump_headers` names a file curl fills in as the response headers
      # arrive -- before the body, which is what makes its Content-Length usable
      # as a live progress total; see Item#size.
      def download(url, destination, headers: {}, dump_headers: nil)
        argv = command(url, headers, destination.to_s, DOWNLOAD_MAX_TIME)
        argv += ['--dump-header', dump_headers.to_s] if dump_headers
        out, err, status = run(argv)
        raise DownloadError, "#{@binary} failed (#{status.exitstatus}): #{err.strip}" unless status.success?

        out.strip.split(' ', 2).first.to_i
      end

      private

      def run(argv)
        Open3.capture3(*argv)
      rescue Errno::ENOENT
        raise ApiError, self.class.missing_binary(@binary)
      end

      def wrapper_majors
        dir = binary_dir or return []

        dir.children.filter_map { |path| path.basename.to_s[/\Acurl_chrome(\d+)\z/, 1]&.to_i }
      rescue SystemCallError
        []
      end

      def binary_dir
        path = @binary.include?('/') ? Pathname(@binary) : which(@binary)
        path&.dirname
      end

      def which(name)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).lazy
           .map { Pathname(it).join(name) }.find(&:executable?)
      end

      # No shell: argv goes straight to exec, so a header value cannot be
      # interpreted as anything but a header value.
      def command(url, headers, output_path, max_time)
        [
          @binary,
          '--compressed',
          '--impersonate', @target,
          '--silent', '--show-error',
          '--connect-timeout', CONNECT_TIMEOUT.to_s,
          '--max-time', max_time.to_s,
          '--output', output_path,
          '--write-out', '%{http_code} %{content_type}',
          *headers.flat_map { |key, value| ['--header', "#{key}: #{value}"] },
          url
        ]
      end
    end
  end
end
