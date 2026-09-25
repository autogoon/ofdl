# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class LoggingTest < TestCase
    # see Logging#initialize
    def test_the_file_gets_every_level_whatever_the_screen_shows
      screen = StringIO.new
      file = StringIO.new
      log = Logging.new(io: screen, level: :info, colour: false, file:)

      log.debug { "HTTP 429\n  retry-after: 30" }
      log.request('/api/v1/users/1/info/')

      refute_match(/429/, screen.string)
      assert_match(/debug: HTTP 429\n  retry-after: 30$/, file.string)
      assert_match(%r{request:   → /api/v1/users/1/info/$}, file.string)
    end

    def test_the_dashboard_sink_does_not_take_the_file_lines
      file = StringIO.new
      log = Logging.new(io: StringIO.new, level: :info, colour: false, file:)
      log.sink = Struct.new(:lines) { def log(line) = lines << line }.new([])

      log.warn('HTTP 429')

      assert_match(/warn: HTTP 429$/, file.string)
    end
  end
end
