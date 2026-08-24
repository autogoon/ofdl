# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'tmpdir'

module OFDL
  class DashboardTest < TestCase
    def setup
      @dir = Dir.mktmpdir('ofdl-dashboard')
      @now = 0.0
      @stats = Stats.new(clock: -> { @now })
      @display = Display.new(io: StringIO.new, header_lines: Dashboard::HEADER_LINES, footer_lines: 4)
      @dashboard = Dashboard.new(stats: @stats, display: @display, concurrency: 4)
    end

    def teardown = FileUtils.remove_entry(@dir)

    def partial(name, bytes)
      path = File.join(@dir, name)
      File.write(path, 'x' * bytes)
      path
    end

    def header = @dashboard.send(:header_lines)

    def footer = @dashboard.send(:footer_lines)

    # Drops the box borders, leaving one line per worker. Samples first because
    # the render path reads only what the sampler measured; see Dashboard#slot.
    def slots
      @dashboard.send(:sample!)
      footer[1..-2]
    end

    # header[0] is the box border; the three columns read downward beneath it.
    def test_the_first_column_follows_the_crawl
      @stats.bump(:creators_total, 12).bump(:creators_done, 3).bump(:requests, 87)
      @stats.bump(:images, 1200).bump(:videos, 216)
      @stats.scanning(creator: 'someone', source: 'posts')

      assert_match(%r{3/12 someone}, header[1])
      assert_match(/scanning\s+posts/, header[2])
      assert_match(/requests\s+87/, header[3])
      assert_match(%r{discovered\s+1,200 images / 216 videos}, header[4])
    end

    # See Stats#done_scanning: the count stays, the name goes.
    def test_the_creators_field_drops_the_name_once_scanning_is_done
      @stats.bump(:creators_total, 12).bump(:creators_done, 12)
      @stats.scanning(creator: 'someone', source: 'posts')

      @stats.done_scanning

      assert_match(%r{creators\s+12/12\s}, header[1])
      refute_match(/someone/, header[1])
      assert_match(/scanning\s+done/, header[2])
    end

    # queued is what is still waiting; the three beneath it are what became of
    # the work that has left the queue.
    def test_the_second_column_accounts_for_everything_queued
      @stats.bump(:queued, 369).bump(:downloaded, 121).bump(:failed, 4).bump(:skipped, 2)

      assert_match(/queued\s+369/, header[1])
      assert_match(/successful\s+121/, header[2])
      assert_match(/skipped\s+2/, header[3])
      assert_match(/failed\s+4/, header[4])
    end

    # "on disk" is what is there now, so it has to include whatever this run has
    # already fetched -- otherwise it stops being a live figure the moment a
    # download lands.
    def test_the_third_column_counts_this_run_as_being_on_disk
      @stats.bump(:on_disk, 1000).bump(:on_disk_bytes, 1_048_576)
      @stats.bump(:downloaded, 47).bump(:bytes, 1_048_576)
      @now = 2.0

      assert_match(%r{on disk\s+1,047 / 2\.0 MB}, header[1])
      assert_match(%r{fetched\s+47 / 1\.0 MB}, header[2])
      assert_match(%r{rate\s+512\.0 KB/s}, header[3])
    end

    def test_header_groups_digits_so_large_counts_stay_readable
      @stats.bump(:images, 4310)

      assert_match(/4,310/, header[4])
    end

    # The percentage comes from the size of the partial file on disk; see
    # Stats#begin_download.
    def test_footer_reads_progress_from_the_partial_file
      @stats.begin_download(0, filename: 'big.mp4', path: partial('a.part', 500_000), total: 1_000_000)

      assert_match(/\[=+ +\]\s+50%/, slots.first)
      assert_match(/big\.mp4/, slots.first)
    end

    # The pool interleaves creators, so the row names its own, and the source
    # is the directory the file lands in; see Dashboard#target.
    def test_a_slot_names_the_creator_and_source_it_is_fetching_for
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 10), total: 100, creator: 'alice',
                               source: 'posts')

      assert_match(%r{alice/posts/a\.jpg}, slots.first)
    end

    def test_a_slot_without_a_creator_shows_the_filename_alone
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 10), total: 100)

      assert_match(/ a\.jpg/, slots.first)
      refute_match(%r{/a\.jpg}, slots.first)
    end

    # Colour is off for the suite, so this is the one place it is turned back on.
    def test_the_creator_is_blue_and_the_filename_cyan
      Palette.enabled = true
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 10), total: 100, creator: 'alice')

      assert_match(%r{\e\[34malice\e\[0m/\e\[36ma\.jpg\e\[0m}, slots.first)
    ensure
      Palette.enabled = false
    end

    # With no total there is nothing to fill the bar with, so no cell is filled
    # and the row carries the bytes written; see ProgressBar#bar.
    def test_an_unsized_item_shows_bytes_rather_than_a_bar
      @stats.begin_download(0, filename: 'unknown.mp4', path: partial('a.part', 300_000), total: 0)
      line = slots.first

      refute_match(/\[=/, line)
      assert_match(/293\.0 KB/, line)
    end

    # The denominator falls back to Content-Length from the header file curl
    # dumps; see Item#size.
    def test_the_total_falls_back_to_content_length_from_the_headers
      headers = File.join(@dir, 'a.part.headers')
      File.write(headers, "HTTP/2 200\r\ncontent-type: image/jpeg\r\ncontent-length: 1000000\r\n\r\n")
      @stats.begin_download(0, filename: 'big.mp4', path: partial('a.part', 500_000),
                               total: 0, headers_path: headers)

      assert_match(/\[=+ +\]\s+50%/, slots.first)
    end

    # A redirect leaves more than one header block; the last one is the transfer
    # that actually happened.
    def test_the_last_content_length_wins_after_a_redirect
      headers = File.join(@dir, 'a.part.headers')
      File.write(headers, "HTTP/2 302\r\ncontent-length: 0\r\n\r\nHTTP/2 200\r\ncontent-length: 1000000\r\n\r\n")
      @stats.begin_download(0, filename: 'big.mp4', path: partial('a.part', 250_000),
                               total: 0, headers_path: headers)

      assert_match(/25%/, slots.first)
    end

    def test_headers_that_have_not_arrived_yet_are_not_fatal
      @stats.begin_download(0, filename: 'big.mp4', path: partial('a.part', 100),
                               total: 0, headers_path: File.join(@dir, 'absent.headers'))

      assert_match(/100 B/, slots.first)
    end

    # The filename starts at the same offset whether the size is known or not;
    # see Dashboard#slot.
    def test_rows_line_up_whether_or_not_the_size_is_known
      sized = File.join(@dir, 's.part.headers')
      File.write(sized, "HTTP/2 200\r\ncontent-length: 1000000\r\n\r\n")
      @stats.begin_download(0, filename: 'sized.mp4', path: partial('s.part', 500_000),
                               total: 0, headers_path: sized)
      @stats.begin_download(1, filename: 'unsized.mp4', path: partial('u.part', 500_000), total: 0)

      offsets = slots.filter_map { |line| Display.strip(line).index(/(?:un)?sized\.mp4/) }

      assert_equal(2, offsets.size, 'expected both rows to carry a filename')
      assert_equal(1, offsets.uniq.size, 'filename column moved between rows')
    end

    def test_an_unknown_total_is_shown_as_a_question_mark
      @stats.begin_download(0, filename: 'a.mp4', path: partial('a.part', 100), total: 0)

      assert_match(%r{100 B / \?}, Display.strip(slots.first))
    end

    # One row per worker, busy or not; see Dashboard#footer_lines.
    def test_the_panel_always_has_one_row_per_worker
      assert_equal(4, slots.size)
      assert(slots.all? { it.match?(/idle/) })

      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 10), total: 100)

      assert_equal(4, slots.size)
      assert_equal(3, slots.count { it.match?(/idle/) })
    end

    def test_the_panel_is_drawn_as_a_titled_box
      assert_match(/┌.*downloading.*┐/, footer.first)
      assert_match(/└─+┘/, footer.last)
    end

    def test_the_panel_shows_how_many_slots_are_busy
      2.times { |i| @stats.begin_download(i, filename: "f#{i}", path: partial("p#{i}", 10), total: 100) }

      assert_match(%r{2/4}, footer.first)
    end

    def test_slots_never_exceed_the_pool_size
      6.times { |i| @stats.begin_download(i, filename: "f#{i}", path: partial("p#{i}", 10), total: 100) }

      assert_equal(4, slots.size)
    end

    # A phase label replaces the bar for the rest of the slot's work; see
    # Stats#phase.
    def test_a_finished_download_reports_its_phase_instead_of_a_bar
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 800_000), total: 800_000)
      @stats.phase(0, :moving)
      line = Display.strip(slots.first)

      refute_match(/\[=/, line)
      assert_match(/moving/, line)
    end

    def test_rendering_and_moving_read_differently
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 10), total: 100)
      @stats.phase(0, :rendering)

      assert_match(/rendering/, Display.strip(slots.first))
    end

    # The size column holds when the bar gives way to a phase label; see
    # Dashboard#lead.
    def test_the_sizes_stay_in_the_same_column_through_the_phases
      @stats.begin_download(0, filename: 'a.jpg', path: partial('a.part', 800_000), total: 800_000)
      downloading = Display.strip(slots.first).index('781.2 KB')
      @stats.phase(0, :moving)
      moving = Display.strip(slots.first).index('781.2 KB')

      assert_equal(downloading, moving, 'the size column moved when the phase changed')
    end

    # The box is the slice's pixel size, undersampled; the cell size falls back
    # to the constants when the terminal reports none. See
    # Dashboard::CELL_WIDTH_PX and Dashboard::UNDERSAMPLE.
    def test_the_thumbnail_box_falls_back_to_the_estimated_cell_size
      slice = @display.columns / 4

      assert_equal([slice * Dashboard::CELL_WIDTH_PX / Dashboard::UNDERSAMPLE,
                    @display.image_lines * Dashboard::CELL_HEIGHT_PX / Dashboard::UNDERSAMPLE],
                   @dashboard.send(:thumbnail_box))
    end

    def test_the_thumbnail_box_uses_the_cell_size_the_terminal_reports
      @display.define_singleton_method(:cell_size) { [7, 15] }
      slice = @display.columns / 4

      assert_equal([slice * 7 / Dashboard::UNDERSAMPLE, @display.image_lines * 15 / Dashboard::UNDERSAMPLE],
                   @dashboard.send(:thumbnail_box))
    end

    def test_a_missing_partial_reads_as_zero
      @stats.begin_download(0, filename: 'gone.mp4', path: File.join(@dir, 'absent.part'), total: 1000)

      assert_match(/0%/, slots.first)
    end

    # The render path reads only what the sampler measured; see Dashboard#slot.
    def test_rendering_touches_no_files
      @stats.begin_download(0, filename: 'a.mp4', path: partial('a.part', 500), total: 0,
                               headers_path: File.join(@dir, 'a.part.headers'))
      @dashboard.send(:sample!)

      reads = 0
      @dashboard.define_singleton_method(:size_of) { |_| reads += 1 }
      @dashboard.define_singleton_method(:content_length) { |_| reads += 1 }

      @dashboard.send(:footer_lines)
      @dashboard.send(:header_lines)

      assert_equal(0, reads, 'the render path hit the filesystem')
    end

    # The first failure is kept for the CLI to report; see Dashboard#safe_paint.
    def test_a_render_failure_is_recorded_rather_than_swallowed
      @display.define_singleton_method(:header) { |_| raise('boom') }

      @dashboard.safe_paint

      assert_match(/boom/, @dashboard.error.message)
    end
  end
end
