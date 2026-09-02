# frozen_string_literal: true

require 'io/console'

module OFDL
  # A terminal split into four zones, top to bottom:
  #
  #   header   fixed    the stats panel
  #   image    fixed    whatever space is left, one preview slice per worker
  #   log      scrolls  a fixed number of rows
  #   footer   fixed    the in-flight downloads
  #
  # DECSTBM, "\e[{top};{bottom}r", tells the terminal that only those lines
  # scroll. Everything above and below stays put; the rest is cursor addressing.
  #
  # A bar that scrolls out of view cannot be redrawn, so in-flight downloads live
  # in the fixed footer and only completed ones scroll away.
  class Display
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    SAVE_CURSOR = "\e7"
    RESTORE_CURSOR = "\e8"
    RESET_REGION = "\e[r"
    CLEAR_LINE = "\e[K"

    # Synchronized output. Between these the terminal buffers rather than
    # painting, so a sequence that blanks a region and then fills it appears in
    # one go instead of flashing empty first. Terminals that do not implement it
    # ignore both sequences.
    BEGIN_SYNC = "\e[?2026h"
    END_SYNC = "\e[?2026l"

    DEFAULT_SIZE = [24, 80].freeze
    MIN_SCROLL_LINES = 3

    # Every redraw ships the whole picture to the terminal as base64 and blocks
    # until the terminal has taken it, so a large one stalls the dashboard for
    # as long as that takes.
    MAX_IMAGE_BYTES = 4 * 1024 * 1024

    attr_reader :rows, :columns, :image_lines

    def initialize(io: $stdout, header_lines: 5, log_lines: 8, footer_lines: 2)
      @io = io
      @header_lines = header_lines
      @log_lines = log_lines
      @footer_lines = footer_lines
      @mutex = Mutex.new
      @started = false
      measure
    end

    def start
      @mutex.synchronize do
        next if @started

        @started = true
        measure
        emit("#{HIDE_CURSOR}\e[2J#{scroll_region}\e[#{@scroll_bottom};1H")
      end
      self
    end

    # Resets the scroll region and parks the cursor below everything, so the
    # shell prompt does not land inside a region the terminal still thinks is
    # constrained.
    def stop
      @mutex.synchronize do
        next unless @started

        @started = false
        emit("#{RESET_REGION}\e[#{@rows};1H\n#{SHOW_CURSOR}")
      end
      self
    end

    # Appends a line to the scrolling middle. Writing at the last line of the
    # region and then advancing is what makes the region -- and only the region
    # -- scroll.
    def log(text)
      line = text.to_s
      return @io.puts(line) unless @started

      @mutex.synchronize do
        emit(atomic("\e[#{@scroll_bottom};1H\n\e[#{@scroll_bottom};1H#{CLEAR_LINE}#{clip(line)}"))
      end
    end

    def header(lines) = paint(1, lines, @header_lines)

    def footer(lines) = paint(@rows - @footer_lines + 1, lines, @footer_lines)

    # Draws into one vertical slice of the image zone -- `slot` of `slots`,
    # counting from zero -- using iTerm2's inline image protocol:
    #
    #   ESC ] 1337 ; File=inline=1;... : <base64> BEL
    #
    # Each worker owns a slice and draws into it directly, so there is no shared
    # image to race over and nothing to throttle.
    #
    # Width and height are in cells, so iTerm2 sizes the picture from the slice.
    # Given pixels, the picture overflows the zone and pushes every other zone
    # off the screen.
    #
    # A vanished or unreadable file returns without drawing: a preview must not
    # interrupt a download.
    def image(path, slot: 0, slots: 1)
      return self unless @started && @image_lines.positive?

      data = File.binread(path)
      return self if data.empty? || data.bytesize > MAX_IMAGE_BYTES

      width = [@columns / slots, 1].max
      left = (slot * width) + 1
      # Blanked and filled in one write, so the slot never sits empty between
      # pictures. Synchronized output covers this for most images; one large
      # enough to outrun the terminal's timeout still shows the blank briefly.
      #
      # Encoded before taking the lock, but written under it: a half-written
      # image interleaved with a panel repaint is garbage on screen.
      payload = "#{clear_slice(left, width)}#{inline_image(data, left, width)}"
      @mutex.synchronize { emit(atomic(payload)) }
      self
    rescue SystemCallError, IOError
      self
    end

    # Recomputes geometry after SIGWINCH. The scroll region is tied to the
    # terminal height, so it has to be re-declared or the zones drift.
    def resize
      return self unless @started

      @mutex.synchronize do
        measure
        emit(scroll_region)
      end
      self
    end

    RESET = "\e[0m"
    ANSI = /\e\[[0-9;]*[A-Za-z]/

    # Cells a string will occupy, ignoring colour codes.
    def self.visible_width(text) = text.to_s.gsub(ANSI, '').length

    def self.strip(text) = text.to_s.gsub(ANSI, '')

    # A prefix, for a value printed to be compared rather than read: enough to
    # check against the browser, not enough to reuse.
    def self.truncate(value, length = 24)
      string = value.to_s
      string.length > length ? "#{string[0, length]}..." : string
    end

    def self.humanize(bytes)
      units = %w[B KB MB GB TB]
      value = bytes.to_f
      units.each_with_index do |unit, index|
        return format(index.zero? ? '%d %s' : '%.1f %s', value, unit) if value < 1024 || index == units.size - 1

        value /= 1024
      end
    end

    # macOS: struct winsize is four unsigned shorts -- rows, cols, and the
    # window's size in pixels. Terminals need not fill the last two in; iTerm2
    # does, so the cell size is exact and follows the font size and display.
    TIOCGWINSZ = 0x40087468

    def self.cell_size(io = $stdout)
      buffer = +"\0" * 8
      io.ioctl(TIOCGWINSZ, buffer)
      rows, columns, x_pixels, y_pixels = buffer.unpack('S4')
      return nil if [rows, columns, x_pixels, y_pixels].any?(&:zero?)

      [x_pixels / columns, y_pixels / rows]
    rescue StandardError
      nil
    end

    def cell_size = Display.cell_size(@io)

    private

    def paint(first_row, lines, allowance)
      return self unless @started

      @mutex.synchronize do
        painted = Array(lines).first(allowance)
        chunks = painted.each_with_index.map do |line, offset|
          "\e[#{first_row + offset};1H#{CLEAR_LINE}#{clip(line)}"
        end
        # Blank any rows the caller did not fill, or stale text survives.
        (painted.size...allowance).each do |offset|
          chunks << "\e[#{first_row + offset};1H#{CLEAR_LINE}"
        end
        emit(atomic(chunks.join))
      end
      self
    end

    def scroll_region = "\e[#{@scroll_top};#{@scroll_bottom}r"

    # The log gets its fixed allowance and the image zone takes what is left, so
    # the log is the same height in any window. Too short for both and the image
    # zone goes first; the log shrinks only to keep the scroll region at
    # MIN_SCROLL_LINES, since terminals reject an inverted one.
    def measure
      @rows, @columns = terminal_size
      spare = @rows - @header_lines - @footer_lines - @log_lines
      @image_lines = [spare, 0].max

      @scroll_top = @header_lines + @image_lines + 1
      @scroll_bottom = @rows - @footer_lines

      return if @scroll_bottom - @scroll_top + 1 >= MIN_SCROLL_LINES

      @scroll_top = @header_lines + 1
      @scroll_bottom = @scroll_top + MIN_SCROLL_LINES - 1
      @image_lines = 0
    end

    def terminal_size
      size = @io.winsize
      size[0] < 1 || size[1] < 1 ? DEFAULT_SIZE : size
    rescue StandardError
      DEFAULT_SIZE
    end

    # A long filename must not wrap, or it pushes the fixed zones out of place.
    # A clipped line gets a reset so its colour cannot leak into the next.
    def clip(text)
      string = text.to_s
      return string if Display.visible_width(string) <= @columns

      kept = +''
      width = 0
      string.scan(/\e\[[0-9;]*[A-Za-z]|./m) do |token|
        if token.start_with?("\e")
          kept << token
          next
        end
        break if width >= @columns - 1

        kept << token
        width += 1
      end
      "#{kept}…#{RESET}"
    end

    # Blanks a rectangle rather than whole lines: the neighbouring slices belong
    # to other workers and must survive.
    def clear_slice(left, width)
      blank = ' ' * width
      (0...@image_lines).map { "\e[#{@header_lines + 1 + it};#{left}H#{blank}" }.join
    end

    def inline_image(data, left, width)
      args = [
        'inline=1',
        "width=#{width}",
        "height=#{@image_lines}",
        # The caller only ever passes a picture already cropped to the slice's
        # shape, so aspect correction would just letterbox something that
        # already fits.
        'preserveAspectRatio=0',
        "size=#{data.bytesize}"
      ].join(';')
      # pack('m0') is strict base64 without line breaks, from core rather than
      # the base64 gem, which stopped being a default gem in Ruby 3.4.
      "\e[#{@header_lines + 1};#{left}H\e]1337;File=#{args}:#{[data].pack('m0')}\a"
    end

    # Wrapped so the cursor is put back where it was, inside the synchronized
    # output pair (see BEGIN_SYNC).
    def atomic(payload) = "#{BEGIN_SYNC}#{SAVE_CURSOR}#{payload}#{RESTORE_CURSOR}#{END_SYNC}"

    def emit(string)
      @io.write(string)
      @io.flush
    rescue IOError, Errno::EPIPE
      nil
    end
  end
end
