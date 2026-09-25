# frozen_string_literal: true

module OFDL
  # Stderr logger, not stdlib Logger: the output is a progress report for a
  # human watching a long run, not an audit log.
  class Logging
    LEVELS = %i[debug info warn error].freeze

    # `file` receives every level, whatever `level` is, and is not affected by
    # the dashboard: its message zone shows the first line of each entry only.
    def initialize(io: $stderr, level: :info, colour: nil, file: nil)
      @io = io
      @level = level
      @colour = colour.nil? ? io.tty? : colour
      @file = file
      @mutex = Mutex.new
      @sink = nil
    end

    # When the dashboard owns the terminal, lines go into its scrolling region
    # rather than straight to the IO, or they would land in the fixed zones.
    attr_accessor :sink

    LEVELS.each_with_index do |name, index|
      define_method(name) do |message = nil, &block|
        shown = index >= LEVELS.index(@level)
        return unless shown || @file

        text = message || block&.call
        record(name, text)
        write(name, text) if shown
      end
    end

    # The /api2/v2 prefix is on every path and carries no information.
    def request(path)
      line = "  → #{path.delete_prefix('/api2/v2')}"
      record(:request, line)
      write(:request, line) unless LEVELS.index(:info) < LEVELS.index(@level)
    end

    def step(message) = info("\n#{message}")

    # Dropped when colour is off: the \r\e[K rewrite needs a tty, and a piped
    # log stays readable without these lines.
    def progress(message)
      return if @sink # the dashboard already shows live state
      return unless @colour

      @mutex.synchronize do
        @io.print("\r\e[K#{message}")
        @io.flush
      end
    end

    def clear_progress
      return unless @colour

      @mutex.synchronize do
        @io.print("\r\e[K")
        @io.flush
      end
    end

    private

    TINTS = { debug: "\e[90m", request: "\e[90m", info: '', warn: "\e[33m", error: "\e[31m" }.freeze
    private_constant :TINTS

    UNLABELLED = %i[info request].freeze
    private_constant :UNLABELLED

    # Some callers build colour into the message itself, so it is stripped
    # here as well as left out of the prefix.
    ESCAPE = /\e\[[0-9;?]*[A-Za-z]/
    private_constant :ESCAPE

    def record(level, message)
      return unless @file

      stamp = Time.now.strftime('%H:%M:%S.%L')
      @mutex.synchronize { @file.puts("#{stamp} #{level}: #{message.to_s.gsub(ESCAPE, '')}") }
    end

    def write(level, message)
      line = if @colour
               "#{TINTS.fetch(level)}#{message}\e[0m"
             else
               "#{"#{level}: " unless UNLABELLED.include?(level)}#{message}"
             end
      if @sink
        @sink.log(line)
        return
      end

      @mutex.synchronize do
        @io.print("\r\e[K") if @colour
        @io.puts(line)
      end
    end
  end
end
