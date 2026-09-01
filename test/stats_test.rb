# frozen_string_literal: true

require_relative 'test_helper'

module OFDL
  class StatsTest < TestCase
    def stats(clock: -> { 0.0 }) = Stats.new(clock:)

    def outcome(status, bytes = 0)
      item = Item.new(media_id: 1, post_id: 2, post_type: 'posts', kind: 'photo',
                      posted_at: Time.now, url: 'u', protected: false, extension: 'jpg')
      Outcome.new(item:, status:, bytes:, message: nil)
    end

    def test_counters_start_at_zero
      assert_equal(0, stats.downloaded)
      assert_equal(0, stats.bytes)
    end

    def test_record_maps_outcomes_onto_counters
      subject = stats
      [outcome(:downloaded, 100), outcome(:skipped), outcome(:protected), outcome(:failed)]
        .each { subject.record(it) }

      assert_equal(1, subject.downloaded)
      assert_equal(100, subject.bytes)
      # A :skipped outcome is already counted by the walk; see Stats#record.
      assert_equal(0, subject.on_disk)
      assert_equal(1, subject.drm)
      assert_equal(1, subject.failed)
    end

    # Adverts are dropped while scanning, so no outcome reaches #record for
    # them; the producer bumps the counter itself.
    def test_adverts_are_counted_apart_from_drm
      subject = stats
      subject.record(outcome(:protected))
      subject.bump(:ads, 3)

      assert_equal(1, subject.drm)
      assert_equal(3, subject.ads)
    end

    def test_tracks_what_is_being_scanned
      subject = stats
      subject.scanning(creator: 'someone', step: 'messages')

      assert_equal('someone', subject.creator)
      assert_equal('messages', subject.step)
    end

    # Nothing is being scanned once the producer is through, so no creator is
    # named for the drain; see Stats#done_scanning.
    def test_scanning_finishes_by_clearing_the_creator
      subject = stats
      subject.scanning(creator: 'someone', step: 'paid')

      subject.done_scanning

      assert_equal('done', subject.step)
      assert_nil(subject.creator)
    end

    def test_active_downloads_are_registered_and_cleared
      subject = stats
      subject.begin_download(0, filename: 'a.jpg', path: '/tmp/a.part', total: 100)

      assert_equal(['a.jpg'], subject.active.values.map { it[:filename] })

      subject.finish_download(0)

      assert_empty(subject.active)
    end

    # See Stats#begin_download for slot ownership.
    def test_slots_are_independent
      subject = stats
      subject.begin_download(0, filename: 'a.jpg', path: '/tmp/a', total: 1)
      subject.begin_download(1, filename: 'b.jpg', path: '/tmp/b', total: 1)
      subject.finish_download(0)

      assert_equal(['b.jpg'], subject.active.values.map { it[:filename] })
    end

    def test_active_returns_copies
      subject = stats
      subject.begin_download(0, filename: 'a.jpg', path: '/tmp/a', total: 1)
      subject.active[0][:filename] = 'tampered'

      assert_equal(['a.jpg'], subject.active.values.map { it[:filename] })
    end

    def test_throughput_is_bytes_over_elapsed
      now = 0.0
      subject = Stats.new(clock: -> { now })
      subject.bump(:bytes, 1000)
      now = 2.0

      assert_in_delta(500.0, subject.throughput)
    end

    def test_throughput_is_zero_before_any_time_passes
      assert_in_delta(0.0, stats.throughput)
    end

    # See the Stats class comment for the concurrent writers.
    def test_counting_is_thread_safe
      subject = stats
      threads = Array.new(8) { Thread.new { 500.times { subject.bump(:media) } } }
      threads.each(&:join)

      assert_equal(4000, subject.media)
    end
  end
end
