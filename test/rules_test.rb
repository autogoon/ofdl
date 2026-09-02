# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class RulesStoreTest < TestCase
    # The `rules_url` of every config here: nothing listens on port 1, so a test
    # that reaches the network raises RulesError instead of passing.
    UNREACHABLE = 'http://127.0.0.1:1/rules.json'

    def setup = @dir = Pathname(Dir.mktmpdir('ofdl-rules'))

    def teardown = FileUtils.remove_entry(@dir)

    def payload
      { 'static_param' => 'S', 'prefix' => 'P', 'suffix' => 'X',
        'checksum_indexes' => [0, 1], 'checksum_constant' => 7 }
    end

    def config_with(hash)
      path = @dir.join('ofdl-config.json')
      path.write(JSON.generate({ 'rules_url' => UNREACHABLE }.merge(hash)))
      Config.new(path)
    end

    def store_for(config) = RulesStore.new(config:, log: silent_log)

    def test_uses_rules_cached_in_the_config
      rules = store_for(config_with({ 'rules' => payload })).load

      assert_equal('S', rules.static_param)
      assert_equal(7, rules.checksum_constant)
    end

    def test_ignores_a_malformed_cache_rather_than_signing_with_it
      config = config_with({ 'rules' => payload.merge('checksum_indexes' => 'nope') })

      assert_raises(RulesError) { store_for(config).load }
    end

    def test_a_pinned_file_beats_the_cache
      pinned = @dir.join('pinned.json')
      pinned.write(JSON.generate(payload.merge('static_param' => 'PINNED')))
      config = config_with({ 'rules' => payload, 'rules_file' => pinned.to_s })

      assert_equal('PINNED', store_for(config).load.static_param)
    end

    def test_refresh_leaves_a_pinned_file_alone
      pinned = @dir.join('pinned.json')
      pinned.write(JSON.generate(payload.merge('static_param' => 'PINNED')))
      config = config_with({ 'rules_file' => pinned.to_s })

      assert_equal('PINNED', store_for(config).refresh!.static_param)
    end

    def test_storing_rules_preserves_the_rest_of_the_config
      config = config_with({ 'output_dir' => '/tmp/ofdl', 'concurrency' => 7 })

      assert(config.store_rules!(payload.merge('fetched_at' => '2026-08-23T00:00:00Z')))

      reloaded = JSON.parse(config.path.read)
      assert_equal('/tmp/ofdl', reloaded['output_dir'])
      assert_equal(7, reloaded['concurrency'])
      assert_equal('S', reloaded.dig('rules', 'static_param'))
      assert_equal('2026-08-23T00:00:00Z', reloaded.dig('rules', 'fetched_at'))
    end

    def test_stored_rules_are_reusable_without_the_network
      config = config_with({})
      config.store_rules!(payload)

      assert_equal('S', store_for(Config.new(config.path)).load.static_param)
    end
  end
end
