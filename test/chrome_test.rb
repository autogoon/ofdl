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

    def test_user_agent_reports_the_running_major
      skip('Chrome not installed') unless Chrome.installed?

      assert_includes(Chrome.user_agent, "Chrome/#{Chrome.major_version}.0.0.0")
    end

    def test_reads_the_version_that_last_ran
      Dir.mktmpdir do |dir|
        Pathname(dir).join(Chrome::LAST_VERSION).write("151.0.7922.174\n")

        assert_equal('151.0.7922.174', Chrome.send(:last_run_version, Pathname(dir)))
      end
    end

    def test_there_is_no_last_run_version_until_chrome_has_started
      Dir.mktmpdir do |dir|
        assert_nil(Chrome.send(:last_run_version, Pathname(dir)))
      end
    end

    def test_a_last_version_file_that_is_not_a_version_is_ignored
      Dir.mktmpdir do |dir|
        Pathname(dir).join(Chrome::LAST_VERSION).write("\n")

        assert_nil(Chrome.send(:last_run_version, Pathname(dir)))
      end
    end
  end
end
