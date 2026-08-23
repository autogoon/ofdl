# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'tmpdir'
require 'ofdl'

# Tests assert on plain text.
OFDL::Palette.enabled = false

module OFDL
  # No test in the suite contacts OnlyFans.
  class TestCase < Minitest::Test
    def silent_log = Logging.new(io: StringIO.new, level: :error, colour: false)

    def sample_rules
      Rules.new(
        static_param: 'STATIC',
        prefix: 'ABC',
        suffix: 'XYZ',
        checksum_indexes: [0, 5, 9],
        checksum_constant: 1000
      )
    end
  end
end
