# frozen_string_literal: true

module OFDL
  module Sources
    class Instagram
      # Supplies `fb_dtsg`, the token Instagram's GraphQL endpoint requires.
      #
      # It is minted into every HTML page the site serves, inside
      #
      #   ["DTSGInitialData",[],{"token":"..."},<n>]
      #
      # and rejected requests come back as {"error":1357004}. Only the reels
      # listing needs it; every other endpoint this source uses is REST and
      # takes the cookies and `x-ig-app-id` alone.
      #
      # Fetched once per run, through the same transport as everything else, so
      # the page is requested with the TLS fingerprint and headers the rest of
      # the run uses.
      class Tokens
        HOME_URL = 'https://www.instagram.com/'

        PATTERN = /"DTSGInitialData",\[\],\{"token":"([^"]+)"/

        def initialize(transport:, jar:, log:)
          @transport = transport
          @jar = jar
          @log = log
          @mutex = Mutex.new
        end

        def fb_dtsg
          @mutex.synchronize { @fb_dtsg ||= fetch }
        end

        private

        def fetch
          response = @transport.get(HOME_URL, headers)
          unless response.success?
            raise ApiError.new("could not read the Instagram page token: HTTP #{response.status}",
                               status: response.status, path: HOME_URL)
          end

          token = response.body[PATTERN, 1]
          raise ApiError.new("no page token found at #{HOME_URL} -- signed out?", path: HOME_URL) unless token

          @log.debug("fb_dtsg: #{Display.truncate(token)}")
          token
        end

        def headers = { 'user-agent' => Chrome.user_agent, 'cookie' => @jar.header }
      end
    end
  end
end
