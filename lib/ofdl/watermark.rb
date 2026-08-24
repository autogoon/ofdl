# frozen_string_literal: true

module OFDL
  # A position in a walk that runs in name order, and the wait for that walk to
  # reach a given name.
  #
  # `pass` publishes the name just completed; `await(name)` returns once the
  # walk has gone past it, or once `finish` says there is no more walking to do.
  # Because the walk is ordered, a name the position has passed without ever
  # being marked is a name the walk does not contain -- which is what lets a
  # creator with no directory yet be waited on like any other.
  #
  # Both sides must order by the same key, or a waiter is released early. See
  # Library#tally and Session#produce, which both order by directory name.
  class Watermark
    def initialize
      @position = nil
      @finished = false
      @mutex = Mutex.new
      @moved = ConditionVariable.new
    end

    def pass(name)
      @mutex.synchronize do
        @position = name
        @moved.broadcast
      end
      self
    end

    def finish
      @mutex.synchronize do
        @finished = true
        @moved.broadcast
      end
      self
    end

    def passed?(name) = @mutex.synchronize { reached?(name) }

    def await(name)
      @mutex.synchronize do
        @moved.wait(@mutex) until reached?(name)
      end
      self
    end

    private

    def reached?(name) = @finished || (!@position.nil? && @position >= name)
  end
end
