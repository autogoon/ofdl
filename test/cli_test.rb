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
      rest, global = absorb(['--post-types', 'posts', '--since', '2026-01-01'])

      assert_equal(['--post-types', 'posts', '--since', '2026-01-01'], rest)
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
      assert_match(/--post-types type,\.\.\./, usage)
      assert_match(/--since DATE/, usage)
      assert_match(/--include-ads/, usage)
      assert_match(/--no-images/, usage)
    end

    def test_the_status_options_are_listed
      assert_match(/status options:/, usage)
      assert_match(/--library-stats/, usage)
    end

    def test_the_subs_options_are_listed
      assert_match(/subs options:/, usage)
      assert_match(/--source app,\.\.\./, usage)
    end

    def test_the_valid_apps_are_named_under_the_option
      assert_match(/--source app,\.\.\..*\n\s+#{Source::ALL.join(', ')}$/, usage)
    end

    def test_source_defaults_to_every_app
      options = { sources: Source::ALL }
      CLI.new.send(:fetch_parser, options).parse!([])

      assert_equal(Source::ALL, options[:sources])
    end

    def test_source_narrows_to_the_apps_named
      options = { sources: Source::ALL }
      CLI.new.send(:fetch_parser, options).parse!(['--source', 'of'])

      assert_equal(%w[onlyfans], options[:sources])
    end

    def test_an_unknown_app_is_an_error_naming_the_apps
      options = { sources: Source::ALL }

      error = assert_raises(ConfigError) { CLI.new.send(:fetch_parser, options).parse!(['--source', 'myspace']) }

      assert_match(/myspace/, error.message)
      assert_match(/onlyfans/, error.message)
    end

    def test_help_is_advertised
      assert_match(/-h, --help/, usage)
    end

    def test_library_stats_is_off_until_asked_for
      options = { library_stats: false }
      CLI.new.send(:status_parser, options).parse!([])

      refute(options[:library_stats])

      CLI.new.send(:status_parser, options).parse!(['--library-stats'])

      assert(options[:library_stats])
    end

    # The flag turns the config default off for one run; it never turns it on.
    def test_include_ads_clears_the_skip
      options = { skip_ads: true }
      CLI.new.send(:fetch_parser, options).parse!(['--include-ads'])

      refute(options[:skip_ads])
    end

    # Beside --post-types rather than in a footnote, and generated, so a type
    # added to Config::POST_TYPES is documented without touching the usage
    # screen.
    def test_the_valid_post_types_are_named_under_the_option
      assert_match(/--post-types type,\.\.\..*\n\s+#{Config::POST_TYPES.join(', ')}$/, usage)
    end
  end

  # A creator name on the command line, optionally prefixed with the app they
  # are on; see CLI#split_name.
  class CLISplitNameTest < TestCase
    def split(name) = CLI.new.send(:split_name, name)

    def test_no_prefix_means_the_default_app
      assert_equal(%w[onlyfans alice], split('alice'))
    end

    def test_a_full_prefix_is_read
      assert_equal(%w[onlyfans alice], split('onlyfans/alice'))
    end

    def test_a_short_prefix_is_read
      assert_equal(%w[onlyfans alice], split('of/alice'))
    end

    # The @ belongs to the creator name, so it is stripped after the prefix, not
    # before it.
    def test_a_leading_at_is_stripped_from_either_form
      assert_equal(%w[onlyfans Alice], split('@Alice'))
      assert_equal(%w[onlyfans Alice], split('of/@Alice'))
    end

    def test_the_creator_name_keeps_its_case
      assert_equal(%w[onlyfans ALICE], split('OF/ALICE'))
    end

    # A slash in a creator name would otherwise be read as a prefix for an app
    # that does not exist, and the run would go on to look the whole thing up.
    def test_an_unknown_prefix_is_an_error_naming_the_apps
      error = assert_raises(ConfigError) { split('tiktok/alice') }

      assert_match(/tiktok/, error.message)
      assert_match(/onlyfans/, error.message)
    end

    def test_instagram_is_read_from_either_short_form
      assert_equal(%w[instagram alice], split('i/alice'))
      assert_equal(%w[instagram alice], split('ig/alice'))
    end
  end

  class CLINamedCreatorsTest < TestCase
    def named(names) = CLI.new.send(:named_creators, names)

    def test_a_leading_at_is_stripped
      assert_equal([{ source: 'onlyfans', username: 'Alice' }, { source: 'onlyfans', username: 'BOB' }],
                   named(['@Alice', 'BOB']))
    end

    # The walk is scoped by source and creator together, so a prefix on the
    # command line has to reach Library#tally; see Session#count_library.
    def test_a_prefix_scopes_the_walk_to_that_app
      assert_equal([{ source: 'onlyfans', username: 'alice' }], named(['of/alice']))
    end

    def test_no_names_scopes_nothing
      assert_nil(named([]))
    end
  end

  class CLIResolveTargetsTest < TestCase
    ROWS = [{ 'id' => 1, 'username' => 'alice' }, { 'id' => 2, 'username' => 'bob' }].freeze

    # A real OnlyFans adapter with the subscription list already answered, so
    # the resolution under test is the adapter's own.
    def resolve(names, sources: Source::ALL)
      config = Config.new(Pathname(Dir.mktmpdir('ofdl-cli')).join('config.json'))
      session = Session.new(config:, log: silent_log)
      adapter = Sources::OnlyFans.new(config:, log: silent_log, stats: session.stats, transport: nil)
      api = Object.new
      api.define_singleton_method(:subscriptions) { ROWS }
      adapter.instance_variable_set(:@api, api)
      session.instance_variable_set(:@adapters, { Source::ONLYFANS => adapter })

      cli = CLI.new
      cli.instance_variable_set(:@session, session)
      cli.send(:resolve_targets, names, sources)
    end

    def test_no_names_means_every_subscription
      assert_equal(%w[alice bob], resolve([]).map { it[:username] })
    end

    def test_a_prefixed_name_resolves_on_that_app
      assert_equal([{ source: 'onlyfans', id: 1, username: 'alice' }], resolve(['of/alice']))
    end

    # --source narrows which apps a run covers, so a name on one it does not
    # cover is a mistake, not a creator to look up.
    def test_a_name_on_an_app_the_run_does_not_cover_is_an_error
      error = assert_raises(ConfigError) { resolve(['onlyfans/alice'], sources: []) }

      assert_match(/onlyfans/, error.message)
    end

    def test_no_names_and_no_apps_means_no_targets
      assert_empty(resolve([], sources: []))
    end

    def test_names_select_a_subset
      assert_equal([{ source: 'onlyfans', id: 2, username: 'bob' },
                    { source: 'onlyfans', id: 1, username: 'alice' }], resolve(%w[bob alice]))
    end

    # See CLI#resolve_targets: a leading @ is stripped and case is ignored.
    def test_a_name_may_carry_an_at_and_any_case
      assert_equal([{ source: 'onlyfans', id: 2, username: 'bob' }], resolve(['@BOB']))
    end

    def test_an_unknown_name_is_an_error
      assert_raises(ConfigError) { resolve(%w[carol]) }
    end
  end
end
