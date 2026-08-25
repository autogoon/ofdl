# frozen_string_literal: true

module OFDL
  # A position in a walk that runs in name order, and the wait for that walk to
  # reach a given name.
  #
  # `pass` publishes the name just completed; `await(name)` returns once the
  # walk has gone past that name, or once `finish` marks the walk complete.
  #
  # Because the walk is ordered, a name the position has passed without ever
  # being marked is a name the walk does not contain, which lets a creator with
  # no directory yet be waited on like any other.
  #
  # Both sides must order by the same key, or a waiter is released early. The
  # walk must also reach every name the producer waits on: a walk over a subset
  # of the creators, in the same order, reaches every one of those names,
  # because the producer waits only on that same subset. An unscoped walk
  # covers a superset of the names the producer waits on. See Library#tally and
  # Session#produce, which both order by Library#walk_key.
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
