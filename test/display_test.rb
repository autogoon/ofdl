# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'

module OFDL
  class DisplayTest < TestCase
    # A StringIO that answers as a terminal, so the escape sequences can be
    # inspected without a real pty.
    class FakeTTY < StringIO
      def initialize(rows: 24, columns: 80)
        super()
        @size = [rows, columns]
      end

      def tty? = true

      def winsize = @size
    end

    def build(rows: 24, columns: 80, header: 3, log: 8, footer: 2)
      io = FakeTTY.new(rows:, columns:)
      [Display.new(io:, header_lines: header, log_lines: log, footer_lines: footer), io]
    end

    # dup first: io.string hands back the live buffer, so truncating it would
    # empty the value we just captured.
    def written(io)
      io.string.dup.tap do
        io.truncate(0)
        io.rewind
      end
    end

    # 24 rows = 3 header + 11 image + 8 log + 2 footer, so the log occupies
    # rows 15..22.
    def test_start_declares_a_scroll_region_around_the_log_only
      display, io = build(rows: 24, header: 3, log: 8, footer: 2)
      display.start

      assert_includes(written(io), "\e[15;22r")
    end

    # See Display#measure.
    def test_the_image_zone_takes_the_slack
      tall, = build(rows: 60, header: 3, log: 8, footer: 2)
      short, = build(rows: 24, header: 3, log: 8, footer: 2)

      assert_equal(47, tall.image_lines)
      assert_equal(11, short.image_lines)
    end

    def test_a_short_terminal_drops_the_image_zone_first
      display, = build(rows: 14, header: 3, log: 8, footer: 2)

      assert_equal(1, display.image_lines)
    end

    def test_stop_releases_the_region_and_restores_the_cursor
      display, io = build
      display.start
      written(io)
      display.stop
      output = written(io)

      assert_includes(output, "\e[r")
      assert_includes(output, Display::SHOW_CURSOR)
    end

    def test_log_writes_at_the_bottom_of_the_scroll_region
      display, io = build(rows: 24, header: 3, footer: 2)
      display.start
      written(io)
      display.log('hello')
      output = written(io)

      assert_includes(output, "\e[22;1H")
      assert_includes(output, 'hello')
    end

    def test_header_paints_from_the_first_row
      display, io = build(header: 3)
      display.start
      written(io)
      display.header(%w[one two])
      output = written(io)

      assert_includes(output, "\e[1;1H")
      assert_includes(output, "\e[2;1H")
    end

    # Without blanking, a shorter header leaves the previous run's text behind.
    def test_header_blanks_rows_the_caller_did_not_fill
      display, io = build(header: 3)
      display.start
      written(io)
      display.header(['only one'])

      assert_includes(written(io), "\e[3;1H\e[K")
    end

    def test_footer_paints_the_last_rows
      display, io = build(rows: 24, footer: 2)
      display.start
      written(io)
      display.footer(%w[a b])
      output = written(io)

      assert_includes(output, "\e[23;1H")
      assert_includes(output, "\e[24;1H")
    end

    # See Display#clip.
    def test_long_lines_are_clipped_to_the_terminal_width
      display, io = build(columns: 20)
      display.start
      written(io)
      display.log('x' * 100)
      output = written(io)

      refute_includes(output, 'x' * 21)
      assert_includes(output, '…')
    end

    def test_a_tiny_terminal_still_yields_a_sane_region
      display, io = build(rows: 6, header: 3, footer: 2)
      display.start
      top, bottom = written(io)[/\e\[(\d+);(\d+)r/].scan(/\d+/).map(&:to_i)

      assert_operator(bottom, :>, top, 'an inverted scroll region is rejected by terminals')
    end

    # A pty leaves the pixel fields of struct winsize at zero (see
    # Display::TIOCGWINSZ), so callers get nil rather than a guess.
    def test_cell_size_is_nil_when_the_terminal_reports_no_pixels
      require 'pty'

      PTY.open do |_master, slave|
        assert_nil(Display.cell_size(slave))
      end
    end

    def test_cell_size_is_nil_for_something_that_is_not_a_terminal
      assert_nil(Display.cell_size(StringIO.new))
    end

    def test_humanize_scales_units
      assert_equal('0 B', Display.humanize(0))
      assert_equal('1.0 KB', Display.humanize(1024))
      assert_equal('2.2 GB', Display.humanize(2_411_724_800))
    end
  end
end
