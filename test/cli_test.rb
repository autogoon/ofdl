# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class CLIGlobalOptionsTest < TestCase
    def absorb(argv)
      global = {}
      cli = CLI.new
      cli.send(:absorb_trailing_globals!, argv, global)
      [argv, global]
    end

    # `ofdl status -v`; see CLI#absorb_trailing_globals!.
    def test_verbose_after_the_subcommand
      rest, global = absorb(['-v'])

      assert_empty(rest)
      assert(global[:verbose])
    end

    def test_leaves_subcommand_options_alone
      rest, global = absorb(['--sources', 'posts', '--since', '2026-01-01'])

      assert_equal(['--sources', 'posts', '--since', '2026-01-01'], rest)
      refute(global[:verbose])
    end

    # `ofdl fetch --help`; see CLI#absorb_trailing_globals! for why this is not
    # left to OptionParser.
    def test_help_after_the_subcommand
      rest, global = absorb(['alice', '--help'])

      assert_equal(['alice'], rest)
      assert(global[:help])
    end
  end

  # One screen carries the whole interface; there is no per-command help.
  class CLIUsageTest < TestCase
    def usage = CLI.new.send(:global_parser, {}).to_s

    def test_every_command_is_listed
      CLI::COMMANDS.each_key { |name| assert_match(/^  #{name}\b/, usage) }
    end

    # Rendered from #fetch_parser, so a new fetch option appears here without
    # the usage screen being touched.
    def test_the_fetch_options_are_listed
      assert_match(/--sources source,\.\.\./, usage)
      assert_match(/--since DATE/, usage)
      assert_match(/--include-ads/, usage)
      assert_match(/--no-images/, usage)
    end

    def test_help_is_advertised
      assert_match(/-h, --help/, usage)
    end

    # The flag turns the config default off for one run; it never turns it on.
    def test_include_ads_clears_the_skip
      options = { skip_ads: true }
      CLI.new.send(:fetch_parser, options).parse!(['--include-ads'])

      refute(options[:skip_ads])
    end

    # Beside --sources rather than in a footnote, and generated, so a source
    # added to Config::SOURCES is documented without touching the usage screen.
    def test_the_valid_sources_are_named_under_the_option
      assert_match(/--sources source,\.\.\..*\n\s+#{Config::SOURCES.join(', ')}$/, usage)
    end
  end

  class CLINamedCreatorsTest < TestCase
    def named(names) = CLI.new.send(:named_creators, names)

    def test_a_leading_at_is_stripped
      assert_equal(%w[Alice BOB], named(['@Alice', 'BOB']))
    end

    def test_no_names_scopes_nothing
      assert_nil(named([]))
    end
  end

  class CLIResolveTargetsTest < TestCase
    ROWS = [{ 'id' => 1, 'username' => 'alice' }, { 'id' => 2, 'username' => 'bob' }].freeze

    # subscriptions is memoised, so seeding it keeps the API out of the test.
    def resolve(names)
      cli = CLI.new
      cli.instance_variable_set(:@subscriptions, ROWS)
      cli.send(:resolve_targets, names)
    end

    def test_no_names_means_every_subscription
      assert_equal(%w[alice bob], resolve([]).map { it[:username] })
    end

    def test_names_select_a_subset
      assert_equal([{ id: 2, username: 'bob' }, { id: 1, username: 'alice' }], resolve(%w[bob alice]))
    end

    # See CLI#resolve_targets: a leading @ is stripped and case is ignored.
    def test_a_name_may_carry_an_at_and_any_case
      assert_equal([{ id: 2, username: 'bob' }], resolve(['@BOB']))
    end

    def test_an_unknown_name_is_an_error
      assert_raises(ConfigError) { resolve(%w[carol]) }
    end
  end
end
