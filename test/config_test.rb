# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class ConfigTest < TestCase
    def setup = @dir = Pathname(Dir.mktmpdir('ofdl-config'))

    def teardown = FileUtils.remove_entry(@dir)

    def write(hash)
      path = @dir.join('ofdl.config.json')
      path.write(JSON.generate(hash))
      path
    end

    def test_applies_defaults_for_absent_keys
      config = Config.new(write({ 'output_dir' => '/tmp/x' }))

      assert_equal(Config::DEFAULTS['concurrency'], config.concurrency)
      assert_equal(Pathname('/tmp/x'), config.output_dir)
    end

    def test_ads_are_skipped_unless_the_config_says_otherwise
      assert_predicate(Config.new(write({ 'output_dir' => '/tmp/x' })), :skip_ads?)
      refute_predicate(Config.new(write({ 'output_dir' => '/tmp/x', 'skip_ads' => false })), :skip_ads?)
    end

    # An absent key is how a config tracks the app; see Config#write_example!.
    def test_init_writes_only_the_required_key
      path = @dir.join('fresh.json')
      Config.new(path).write_example!

      assert_equal(%w[output_dir], JSON.parse(path.read).keys)
    end

    def test_output_dir_has_no_default_and_is_required
      refute(Config::DEFAULTS.key?('output_dir'))

      error = assert_raises(ConfigError) { Config.new(write({ 'concurrency' => 2 })).output_dir }

      assert_match(/set "output_dir"/, error.message)
    end

    # The placeholder cannot work, so an unedited config fails rather than
    # archiving into an invented directory.
    def test_the_written_placeholder_is_not_a_usable_directory
      refute(Pathname(Config::OUTPUT_DIR_PLACEHOLDER).exist?)
    end

    def test_rejects_unknown_post_types
      error = assert_raises(ConfigError) { Config.new(write({ 'post_types' => %w[posts nonsense] })) }

      assert_match(/unknown post types: nonsense/, error.message)
    end

    def test_rejects_nonsense_concurrency
      assert_raises(ConfigError) { Config.new(write({ 'concurrency' => 0 })) }
    end

    def test_dashboard_settings_have_defaults
      config = Config.new(write({}))

      assert_predicate(config, :images?)
      assert_in_delta(0.05, config.refresh)
    end

    def test_dashboard_settings_can_be_configured
      config = Config.new(write({ 'images' => false, 'refresh' => 0.25 }))

      refute_predicate(config, :images?)
      assert_in_delta(0.25, config.refresh)
    end

    # A zero refresh would spin the render thread flat out.
    def test_rejects_a_nonsense_refresh
      assert_raises(ConfigError) { Config.new(write({ 'refresh' => 0 })) }
    end

    def test_reports_bad_json_with_the_path
      path = @dir.join('ofdl.config.json')
      path.write('{ nope')

      error = assert_raises(ConfigError) { Config.new(path) }

      assert_match(/is not valid JSON/, error.message)
    end

    # Discovery reads the one given path, with no walk up from the working
    # directory; see Config.discover.
    def test_discovery_uses_the_home_location
      path = write({ 'output_dir' => '/tmp/found' })

      config = Config.discover(path: path.to_s)

      assert_equal(Pathname('/tmp/found'), config.output_dir)
    end

    def test_discovery_tolerates_a_missing_config
      config = Config.discover(path: @dir.join('absent.json').to_s)

      assert_equal(Config::DEFAULTS['concurrency'], config.concurrency)
      refute_predicate(config, :exist?)
    end

    # `init` is the fix, and the message says so.
    def test_a_missing_config_is_named_when_output_dir_is_needed
      config = Config.discover(path: @dir.join('absent.json').to_s)

      error = assert_raises(ConfigError) { config.output_dir }

      assert_match(/no config at .*absent\.json -- run `ofdl init`/, error.message)
    end

    def test_the_generated_example_is_valid
      config = Config.discover(path: @dir.join('ofdl-config.json').to_s)
      path = config.write_example!

      assert_equal(Config::DEFAULTS['concurrency'], Config.new(path).concurrency)
    end
  end
end
