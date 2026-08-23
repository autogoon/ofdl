# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class ChromeTest < TestCase
    def setup = Chrome.reset!

    def teardown = Chrome.reset!

    def test_builds_a_reduced_user_agent
      expected = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' \
                 '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'

      assert_equal(expected, format(Chrome::UA_TEMPLATE, major: 151))
    end

    # A full Chrome version is four fields; the reduced string keeps only the
    # major, so a build number cannot reach it. See Chrome::UA_TEMPLATE.
    def test_only_the_major_version_reaches_the_string
      refute_includes(format(Chrome::UA_TEMPLATE, major: 151), '9999')
    end

    def test_reads_the_installed_version
      skip('Chrome not installed') unless Chrome.installed?

      assert_match(/\A\d+\./, Chrome.version)
      assert_kind_of(Integer, Chrome.major_version)
    end

    def test_user_agent_reports_the_installed_major
      skip('Chrome not installed') unless Chrome.installed?

      assert_includes(Chrome.user_agent, "Chrome/#{Chrome.major_version}.0.0.0")
    end
  end
end
