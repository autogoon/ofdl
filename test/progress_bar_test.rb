# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class ProgressBarTest < TestCase
    def bar(total: 50_000_000, width: 20) = ProgressBar.new(total:, width:)

    def test_renders_a_bracketed_bar
      assert_match(/\A\[=+ +\]\z/, bar.bar(20_000_000))
    end

    def test_percent_reflects_the_fraction
      assert_equal('40%', bar.percent(20_000_000))
    end

    # The fixed columns in Dashboard#slot depend on this.
    def test_the_bar_is_a_constant_width_in_every_state
      subject = bar
      widths = [0, 1, 12_345, 25_000_000, 50_000_000, 999_999_999].map { subject.bar(it).length }

      assert_equal([20], widths.uniq)
    end

    def test_an_unknown_total_still_fills_the_width
      unsized = ProgressBar.new(total: 0, width: 20)

      assert_equal(20, unsized.bar(1234).length)
      assert_equal('--', unsized.percent(1234))
      refute_predicate(unsized, :known?)
    end

    def test_an_unknown_total_does_not_divide_by_zero
      assert_in_delta(0.0, ProgressBar.new(total: 0).fraction(1234))
    end

    def test_empty_at_zero
      assert_match(/\A\[ +\]\z/, bar.bar(0))
      assert_equal('0%', bar.percent(0))
    end

    def test_full_at_total
      assert_match(/\A\[=+\]\z/, bar.bar(50_000_000))
      assert_equal('100%', bar.percent(50_000_000))
    end

    def test_overshooting_the_total_stays_full_rather_than_overflowing
      assert_match(/\A\[=+\]\z/, bar.bar(999_999_999))
      assert_equal('100%', bar.percent(999_999_999))
    end

    def test_carries_no_control_sequences
      refute_match(/\e/, bar.bar(20_000_000))
    end

    def test_a_silly_width_still_renders
      assert_kind_of(String, ProgressBar.new(total: 100, width: 1).bar(50))
    end
  end
end
