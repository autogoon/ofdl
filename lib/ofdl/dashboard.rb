# frozen_string_literal: true

module OFDL
  # One render thread reads Stats and repaints the two fixed panels; a sampler
  # thread does the filesystem reads they need.
  #
  # Live byte progress comes from stat()ing each in-flight scratch file, because
  # curl writes the file itself and offers no progress callback.
  class Dashboard
    STATUS_ROWS = 4
    HEADER_LINES = STATUS_ROWS + 2 # the box borders
    LOG_LINES = 8
    REFRESH_SECONDS = 0.1

    # Slower than the refresh: the bars do not need resampling on every frame.
    SAMPLE_INTERVAL = 0.2

    TOP_LEFT = '┌'
    TOP_RIGHT = '┐'
    BOTTOM_LEFT = '└'
    BOTTOM_RIGHT = '┘'
    HORIZONTAL = '─'
    VERTICAL = '│'

    attr_reader :error

    def initialize(stats:, display:, concurrency:, images: true, refresh: REFRESH_SECONDS)
      @stats = stats
      @display = display
      @concurrency = concurrency
      @images = images
      @refresh = refresh
      @running = false
      @error = nil
      @progress = {}
      @progress_mutex = Mutex.new
    end

    def self.build(stats:, concurrency:, io: $stdout, images: true, refresh: REFRESH_SECONDS)
      display = Display.new(io:, header_lines: HEADER_LINES, log_lines: LOG_LINES,
                            footer_lines: concurrency + 2)
      new(stats:, display:, concurrency:, images:, refresh:)
    end

    def log(line) = @display.log(line)

    # The stats panel, for printing once the screen has been handed back. Reusing
    # it rather than formatting a separate summary keeps the two from diverging.
    def summary = header_lines

    # Called by the worker that owns `slot`, on its own download thread, while it
    # still owns `path`.
    def show(slot, path)
      return unless @images

      width, height = thumbnail_box
      # Nothing is drawn if the resize fails; see Thumbnail.build.
      thumbnail = Thumbnail.build(path, "#{path}.thumb.jpg", width:, height:)
      @display.image(thumbnail, slot:, slots: @concurrency) if thumbnail
    ensure
      begin
        File.delete(thumbnail) if thumbnail
      rescue SystemCallError
        nil
      end
    end

    # Fallback when the terminal reports no cell size: a Retina cell, 8 points
    # by 16 at two device pixels each. A wrong guess distorts the picture; it
    # does not leave a gap, since the crop still fills the slice.
    CELL_WIDTH_PX = 16
    CELL_HEIGHT_PX = 32

    # At the slice's true pixel size the payload outruns the terminal's
    # synchronized-output window, and the blank that precedes the picture gets
    # painted on its own. Halving keeps the redraw inside one frame; the
    # undersampling is not visible at this size.
    UNDERSAMPLE = 2

    # The slice's size in pixels, which is what the picture is cropped to.
    def thumbnail_box
      cell_width, cell_height = @display.cell_size || [CELL_WIDTH_PX, CELL_HEIGHT_PX]
      slice = [@display.columns / @concurrency, 1].max
      [slice * cell_width / UNDERSAMPLE, @display.image_lines * cell_height / UNDERSAMPLE]
    end

    def start
      @display.start
      @running = true
      @winch = trap('WINCH') { @display.resize }
      sample!
      @thread = Thread.new { paint while @running }
      @sampler = Thread.new { sample_loop }
      self
    end

    def images? = @images

    def stop
      @running = false
      @thread&.join(1)
      @sampler&.kill
      safe_paint
      @display.stop
      trap('WINCH', @winch || 'DEFAULT')
      self
    end

    # A render failure must not stop the downloads, but it must not pass
    # unnoticed either -- the panels just freeze. The first one is kept for the
    # CLI to report once the screen is back.
    def safe_paint
      @display.header(header_lines)
      @display.footer(footer_lines)
      count_frame
    rescue StandardError => e
      @error ||= e
      @running = false
    end

    private

    def paint
      safe_paint
      sleep(@refresh)
    end

    # The achieved rate, not the configured one: they diverge whenever something
    # holds the interpreter long enough to starve the render thread.
    def count_frame
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @frames = (@frames || 0) + 1
      @fps_since ||= now
      elapsed = now - @fps_since
      return if elapsed < 1.0

      @fps = @frames / elapsed
      @io_ms = (@sample_seconds || 0) * 1000
      @frames = 0
      @fps_since = now
    end

    def width = @display.columns

    # -- header ---------------------------------------------------------------

    # Three columns, each read downward.
    def header_lines
      counts = @stats.snapshot
      on_disk = counts[:on_disk] + counts[:downloaded]
      on_disk_bytes = counts[:on_disk_bytes] + counts[:bytes]
      creators = "#{counts[:creators_done]}/#{counts[:creators_total]}"
      creators += " #{@stats.creator}" if @stats.creator

      [
        box_top(title: 'ofdl', right: Palette.grey("#{fps_label}#{duration(@stats.elapsed)}")),
        *rows_from(
          [
            field('creators', creators, :cyan),
            field('scanning', @stats.source || '-', :cyan),
            field('requests', number(counts[:requests])),
            field('discovered', "#{number(counts[:images])} images / #{number(counts[:videos])} videos")
          ],
          [
            field('queued', number(counts[:queued])),
            field('successful', number(counts[:downloaded]), :green),
            field('skipped', Palette.tally(counts[:skipped], :yellow)),
            field('failed', Palette.tally(counts[:failed], :red))
          ],
          [
            field('on disk', "#{number(on_disk)} / #{Display.humanize(on_disk_bytes)}"),
            field('fetched', "#{number(counts[:downloaded])} / #{Display.humanize(counts[:bytes])}"),
            field('rate', "#{Display.humanize(@stats.throughput)}/s")
          ]
        ),
        box_bottom
      ]
    end

    # Turns columns into the rows the display wants, padding the short ones.
    def rows_from(*columns)
      depth = columns.map(&:size).max
      Array.new(depth) do |index|
        row(columns.map { it[index].to_s }, pad: true)
      end
    end

    # -- footer ---------------------------------------------------------------

    # One row per worker, busy or not, so the panel is a fixed height and
    # nothing below it moves as transfers come and go.
    def footer_lines
      active = @stats.active
      rows = Array.new(@concurrency) do |index|
        entry = active[index]
        row([entry ? slot(entry) : Palette.grey('idle')], pad: false)
      end
      [box_top(title: 'downloading', right: Palette.grey("#{active.size}/#{@concurrency}"))] +
        rows + [box_bottom]
    end

    # Fixed columns: bar, percent, transferred, total, name. A row with no size
    # yet still fills every one -- empty bar, "--", "?" -- so nothing shifts
    # sideways when the headers land mid-download.
    SIZE_COLUMN = 9
    PERCENT_COLUMN = 4

    PHASES = { rendering: 'rendering', moving: 'moving' }.freeze

    # `private` above does not reach constants, so say it for each.
    private_constant :SIZE_COLUMN, :PERCENT_COLUMN, :PHASES

    # Reads only what the sampler measured. A stat() can block for milliseconds,
    # which is more than the render thread has to spend.
    def slot(entry)
      measured = progress_for(entry[:slot])
      written = measured[:written]
      total = measured[:total]

      [
        lead(entry, written, total),
        "#{Display.humanize(written).rjust(SIZE_COLUMN)} / #{total_label(total).ljust(SIZE_COLUMN)}",
        target(entry)
      ].join('  ')
    end

    # <creator>/<source>/<file>, the library layout. The row carries the creator
    # because the pool interleaves them: the header names the creator being
    # scanned, which is ahead of the one this slot is fetching.
    def target(entry)
      [entry[:creator] && Palette.blue(entry[:creator]),
       entry[:source] && Palette.cyan(entry[:source]),
       Palette.cyan(entry[:filename].to_s)].compact.join('/')
    end

    # The bar, or the phase label once Stats#phase has been set. The label is
    # padded to the width of the bar and the percentage, so the sizes beside it
    # hold their column either way.
    def lead(entry, written, total)
      label = PHASES[entry[:phase]]
      return Palette.yellow(label.ljust(bar_width + 2 + PERCENT_COLUMN)) if label

      bar = ProgressBar.new(total:, width: bar_width)
      "#{Palette.grey(bar.bar(written))}  #{bar.percent(written).rjust(PERCENT_COLUMN)}"
    end

    def total_label(total) = total.positive? ? Display.humanize(total) : '?'

    def progress_for(key)
      @progress_mutex.synchronize { @progress[key] } || { written: 0, total: 0 }
    end

    # One pass of every filesystem read the panel needs, done on the sampler
    # thread. Rebuilt wholesale rather than updated in place, so finished
    # downloads drop out and nothing accumulates over a long run.
    def sample!
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      measured = @stats.active.transform_values do |entry|
        { written: size_of(entry[:path]), total: total_for(entry) }
      end
      @progress_mutex.synchronize { @progress = measured }
      @sample_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      self
    end

    def sample_loop
      while @running
        sample!
        sleep(SAMPLE_INTERVAL)
      end
    rescue StandardError
      nil # the loop ends; the panel keeps showing the last reading
    end

    # Falls back to Content-Length from the header file curl dumps, for the
    # media the API gave no size for; see Item#size. Not cached: the value
    # appears partway through a transfer, so a cache keyed by filename would pin
    # the pre-header zero and grow for the length of the run.
    def total_for(entry)
      declared = entry[:total].to_i
      declared.positive? ? declared : content_length(entry[:headers_path])
    end

    def content_length(path)
      return 0 unless path && File.exist?(path)

      File.read(path).scan(/^content-length:\s*(\d+)/i).flatten.last.to_i
    rescue SystemCallError
      0
    end

    def bar_width = (width / 5).clamp(ProgressBar::MIN_WIDTH, 20)

    # -- box drawing ----------------------------------------------------------

    def box_top(title:, right: '')
      label = " #{Palette.bold(title)} "
      tail = right.empty? ? '' : " #{right} "
      fill = width - 2 - Display.visible_width(label) - Display.visible_width(tail) - 2
      "#{grey(TOP_LEFT + HORIZONTAL)}#{label}#{grey(HORIZONTAL * [fill, 0].max)}#{tail}#{grey(HORIZONTAL + TOP_RIGHT)}"
    end

    def box_bottom = grey(BOTTOM_LEFT + (HORIZONTAL * (width - 2)) + BOTTOM_RIGHT)

    # Content between the verticals, padded so the right edge lines up whatever
    # the values are.
    def row(fields, pad: true)
      inner = width - 4
      content = pad ? columns(fields, inner) : fields.join
      content = clip_to(content, inner)
      padding = ' ' * [inner - Display.visible_width(content), 0].max
      "#{grey(VERTICAL)} #{content}#{padding} #{grey(VERTICAL)}"
    end

    # Equal-width columns, which keeps the numbers in the same place as they
    # grow.
    def columns(fields, inner)
      each = inner / fields.size
      fields.each_with_index.map do |text, index|
        index == fields.size - 1 ? text : text + (' ' * [each - Display.visible_width(text), 1].max)
      end.join
    end

    def field(label, value, colour = nil)
      return '' if label.nil?

      shown = colour ? Palette.paint(value.to_s, colour) : value.to_s
      "#{Palette.grey(label.ljust(11))} #{shown}"
    end

    def clip_to(text, limit)
      return text if Display.visible_width(text) <= limit

      Display.strip(text)[0, limit]
    end

    def grey(text) = Palette.grey(text)

    # -- helpers --------------------------------------------------------------

    def size_of(path)
      File.size(path)
    rescue SystemCallError
      0
    end

    def fps_label
      return '' unless @fps

      format('%.0f fps · io %.0fms · ', @fps, @io_ms || 0)
    end

    def duration(seconds)
      total = seconds.to_i
      total < 60 ? "#{total}s" : format('%dm%02ds', total / 60, total % 60)
    end

    def number(value) = value.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
  end
end
