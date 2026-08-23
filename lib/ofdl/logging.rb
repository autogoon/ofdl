# frozen_string_literal: true

module OFDL
  # Stderr logger, not stdlib Logger: the output is a progress report for a
  # human watching a long run, not an audit log.
  class Logging
    LEVELS = %i[debug info warn error].freeze

    def initialize(io: $stderr, level: :info, colour: nil)
      @io = io
      @level = level
      @colour = colour.nil? ? io.tty? : colour
      @mutex = Mutex.new
      @sink = nil
    end

    # When the dashboard owns the terminal, lines go into its scrolling region
    # rather than straight to the IO, or they would land in the fixed zones.
    attr_accessor :sink

    LEVELS.each_with_index do |name, index|
      define_method(name) do |message = nil, &block|
        return if index < LEVELS.index(@level)

        write(name, message || block&.call)
      end
    end

    # The /api2/v2 prefix is on every path and carries no information.
    def request(path)
      return if LEVELS.index(:info) < LEVELS.index(@level)

      write(:request, "  → #{path.delete_prefix('/api2/v2')}")
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
