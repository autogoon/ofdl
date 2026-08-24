# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'

module OFDL
  class WatermarkTest < TestCase
    def setup = @watermark = Watermark.new

    def test_nothing_is_passed_before_the_walk_starts
      refute(@watermark.passed?('alice'))
    end

    def test_a_name_the_walk_has_reached_is_passed
      @watermark.pass('alice')

      assert(@watermark.passed?('alice'))
      refute(@watermark.passed?('bob'))
    end

    # What lets a creator with no directory be waited on: the walk is ordered,
    # so a name the position has gone past is a name the walk does not hold.
    def test_a_name_the_walk_went_past_without_marking_is_passed
      @watermark.pass('bob')

      assert(@watermark.passed?('alice'))
    end

    def test_finishing_passes_everything_left
      @watermark.finish

      assert(@watermark.passed?('zoe'))
    end

    def test_await_returns_once_the_walk_reaches_the_name
      waiter = Thread.new { @watermark.await('bob') }
      @watermark.pass('alice')
      @watermark.pass('bob')

      assert_same(@watermark, Timeout.timeout(5) { waiter.value })
    end

    def test_await_returns_when_the_walk_finishes_without_the_name
      waiter = Thread.new { @watermark.await('zoe') }
      @watermark.pass('alice')
      @watermark.finish

      assert_same(@watermark, Timeout.timeout(5) { waiter.value })
    end
  end
end
