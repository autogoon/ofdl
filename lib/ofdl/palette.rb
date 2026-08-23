# frozen_string_literal: true

module OFDL
  # ANSI colour codes, applied or omitted.
  #
  # Every helper returns the text unchanged when colour is off, so callers never
  # branch. Only the test helper turns it off.
  module Palette
    CODES = {
      reset: 0, bold: 1, dim: 2,
      red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, grey: 90
    }.freeze

    class << self
      def enabled?
        @enabled.nil? || @enabled
      end

      attr_writer :enabled

      CODES.each_key do |name|
        next if name == :reset

        define_method(name) { |text| paint(text, name) }
      end

      def paint(text, *names)
        return text.to_s unless enabled?

        codes = names.map { CODES.fetch(it) }.join(';')
        "\e[#{codes}m#{text}\e[0m"
      end

      # A zero is greyed so the dashboard's "failed" field does not print a
      # red 0.
      def tally(value, colour)
        value.to_i.zero? ? grey(value.to_s) : paint(value.to_s, colour, :bold)
      end
    end
  end
end
