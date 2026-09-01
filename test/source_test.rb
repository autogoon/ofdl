# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class SourceTest < TestCase
    def test_a_full_name_resolves_to_itself
      assert_equal('onlyfans', Source.resolve('onlyfans'))
    end

    def test_a_short_form_resolves_to_the_full_name
      assert_equal('onlyfans', Source.resolve('of'))
    end

    # The prefix is typed, so it is matched the way a creator name is.
    def test_case_is_ignored
      assert_equal('onlyfans', Source.resolve('OnlyFans'))
      assert_equal('onlyfans', Source.resolve('OF'))
    end

    # An app is listed once it can be fetched from, so a name for one that
    # cannot resolves to nothing rather than to a source with no adapter.
    def test_an_unsupported_app_does_not_resolve
      assert_nil(Source.resolve('instagram'))
      assert_nil(Source.resolve('nonsense'))
    end

    def test_every_short_form_resolves
      Source::ALIASES.each do |name, short|
        short.each { assert_equal(name, Source.resolve(it)) }
      end
    end

    def test_all_lists_the_full_names
      assert_equal(%w[onlyfans], Source::ALL)
    end
  end
end
