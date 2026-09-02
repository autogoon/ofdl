# frozen_string_literal: true

require 'json'
require 'time'
require 'net/http'
require 'uri'

module OFDL
  # OnlyFans signs its private API requests with parameters it rotates
  # periodically. They are public values, not credentials.
  #
  # `rules_url` is fetched with no cookies and no identifying headers. Setting
  # `rules_file` pins a copy, and nothing is fetched.
  Rules = Data.define(:static_param, :prefix, :suffix, :checksum_indexes, :checksum_constant) do
    def self.parse(payload)
      raise RulesError, 'rules payload must be a JSON object' unless payload.is_a?(Hash)

      rules = new(
        static_param: payload['static_param'],
        prefix: payload['prefix'],
        suffix: payload['suffix'],
        checksum_indexes: payload['checksum_indexes'],
        checksum_constant: payload['checksum_constant']
      )
      rules.validate!
      rules
    end

    def validate!
      %i[static_param prefix suffix].each do |field|
        value = public_send(field)
        raise RulesError, "rules.#{field} must be a string" unless value.is_a?(String) && !value.empty?
      end
      unless checksum_indexes.is_a?(Array) && checksum_indexes.all?(Integer) && !checksum_indexes.empty?
        raise RulesError, 'rules.checksum_indexes must be a non-empty array of integers'
      end
      raise RulesError, 'rules.checksum_constant must be an integer' unless checksum_constant.is_a?(Integer)

      self
    end

    def to_h_json = { static_param:, prefix:, suffix:, checksum_indexes:, checksum_constant: }
  end

  # Supplies Rules, cached in the config file. There is no expiry: a signature
  # OnlyFans rejects is what triggers a refetch.
  class RulesStore
    def initialize(config:, log:)
      @config = config
      @log = log
    end

    def load
      pinned || cached || refresh!
    end

    # Fetches unless `rules_file` pins a copy, and writes what it fetched back
    # to the config file.
    def refresh!
      if (rules = pinned)
        @log.debug('rules: pinned, not refreshing')
        return rules
      end

      rules = fetch
      if @config.store_rules!(rules.to_h_json.merge(fetched_at: Time.now.utc.iso8601))
        @log.debug("rules: cached in #{@config.path}")
      else
        @log.warn("rules: could not write to #{@config.path}; will refetch next run")
      end
      rules
    end

    private

    def pinned
      path = @config.rules_file or return nil
      raise RulesError, "rules_file #{path} does not exist" unless path.file?

      @log.debug("rules: pinned #{path}")
      Rules.parse(JSON.parse(path.read))
    end

    def cached
      payload = @config.cached_rules or return nil

      rules = Rules.parse(payload)
      @log.debug("rules: from #{@config.path}#{" (fetched #{payload['fetched_at']})" if payload['fetched_at']}")
      rules
    rescue RulesError => e
      @log.warn("rules: ignoring bad cache in #{@config.path} (#{e.message})")
      nil
    end

    def fetch
      uri = URI(@config.rules_url)
      @log.debug("rules: fetching #{uri}")
      response = Net::HTTP.get_response(uri, { 'Cache-Control' => 'no-cache', 'Accept' => 'application/json' })
      raise RulesError, "rules fetch failed: HTTP #{response.code} from #{uri}" unless response.is_a?(Net::HTTPSuccess)

      Rules.parse(JSON.parse(response.body))
    rescue JSON::ParserError => e
      raise RulesError, "rules fetch returned invalid JSON: #{e.message}"
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
      raise RulesError, "rules fetch failed: #{e.message}"
    end
  end
end
