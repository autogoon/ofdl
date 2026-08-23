# frozen_string_literal: true

require 'digest'

module OFDL
  # Reproduces OnlyFans' request signature.
  #
  #   digest   = hex(SHA1("#{static_param}\n#{time}\n#{path}\n#{user_id}"))
  #   checksum = sum(digest[i].ord for i in checksum_indexes) + checksum_constant
  #   sign     = "#{prefix}:#{digest}:#{checksum.to_s(16)}:#{suffix}"
  #
  # `path` is the "/api2/v2/..." request path plus its serialised query string,
  # exactly as sent. Signing a string that differs from the path on the wire --
  # by even one extra parameter -- yields a valid-looking signature the server
  # rejects.
  class Signer
    APP_TOKEN = '33d57ade8c02dbc5a333db99ff9ae26a'

    def initialize(rules:, user_id:, xbc:)
      @rules = rules
      @user_id = user_id.to_s
      @xbc = xbc.to_s
    end

    def headers_for(path, now: Time.now)
      time = (now.to_f * 1000).round.to_s
      digest = Digest::SHA1.hexdigest([@rules.static_param, time, path, @user_id].join("\n"))

      {
        'app-token' => APP_TOKEN,
        'user-id' => @user_id,
        'x-bc' => @xbc,
        'sign' => sign(digest),
        'time' => time
      }
    end

    private

    def sign(digest)
      checksum = @rules.checksum_indexes.sum { |i| digest[i].ord } + @rules.checksum_constant
      [@rules.prefix, digest, checksum.to_s(16), @rules.suffix].join(':')
    end
  end
end
