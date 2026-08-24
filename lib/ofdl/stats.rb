# frozen_string_literal: true

module OFDL
  # Counters for one run, written from the producer thread (scanning), the
  # download pool (fetching) and the client (requests), and read by the
  # dashboard's render and sampler threads.
  class Stats
    # `queued` is a gauge, not a tally: the producer bumps it up as it finds
    # work and a worker bumps it down as it takes one.
    COUNTERS = %i[
      creators_total creators_done requests media images videos queued
      downloaded on_disk skipped failed bytes on_disk_bytes
    ].freeze

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @mutex = Mutex.new
      @counts = COUNTERS.to_h { [it, 0] }
      @active = {}
      @creator = nil
      @source = nil
      @started_at = @clock.call
    end

    COUNTERS.each do |name|
      define_method(name) { @mutex.synchronize { @counts[name] } }
    end

    def bump(name, by = 1)
      @mutex.synchronize { @counts[name] += by }
      self
    end

    def scanning(creator:, source:)
      @mutex.synchronize do
        @creator = creator
        @source = source
      end
      self
    end

    # The producer has walked every source; the pool may still be draining.
    # Without this the fields hold the last source and creator listed, which
    # reads as though that creator were still being scanned for the whole of
    # the drain -- and the pool is draining work from all of them.
    def done_scanning
      @mutex.synchronize do
        @source = 'done'
        @creator = nil
      end
      self
    end

    def creator = @mutex.synchronize { @creator }

    def source = @mutex.synchronize { @source }

    def elapsed = @clock.call - @started_at

    def throughput
      seconds = elapsed
      seconds.positive? ? bytes / seconds : 0.0
    end

    def snapshot
      @mutex.synchronize { @counts.dup }
    end

    # In-flight downloads, keyed by worker slot. A worker owns its slot for the
    # life of the run, so it claims and releases without touching anything
    # another worker is using. The panel row for slot 2 is always slot 2, rather
    # than moving as the set of active downloads changes.
    #
    # `path` is the scratch file: the sampler stats it for live byte progress,
    # which avoids threading a callback down through curl.
    def begin_download(slot, filename:, path:, total:, headers_path: nil, creator: nil, source: nil)
      @mutex.synchronize { @active[slot] = { slot:, filename:, path:, total:, headers_path:, creator:, source: } }
      self
    end

    # What the slot is doing now that its bytes have arrived. A progress bar
    # sitting at 100% says nothing about the copy still in progress behind it.
    def phase(slot, name)
      @mutex.synchronize { @active[slot][:phase] = name if @active[slot] }
      self
    end

    def finish_download(slot)
      @mutex.synchronize { @active.delete(slot) }
      self
    end

    def active = @mutex.synchronize { @active.transform_values(&:dup) }

    def record(outcome)
      case outcome.status
      when :downloaded then bump(:downloaded).bump(:bytes, outcome.bytes)
      # An Outcome's :protected means DRM, which the panel calls "skipped". A
      # :skipped outcome -- the file was already there -- bumps nothing: the
      # walk counted that file into `on_disk` before the producer was allowed
      # to list its creator; see Session#count_library.
      when :protected then bump(:skipped)
      when :failed then bump(:failed)
      end
      self
    end
  end
end
