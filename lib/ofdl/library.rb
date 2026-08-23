# frozen_string_literal: true

require 'fileutils'

module OFDL
  # The output tree is the only record of what has been downloaded. There is no
  # index to fall out of sync with the disk: a file that exists was completed,
  # because completion is an atomic rename from `.part` into place (see
  # Scratch#publish).
  #
  #   <output_dir>/<username>/<source>/<date>_<post_id>_<media_id>.<ext>
  #   <output_dir>/<username>/<source>/<date>_<post_id>_<media_id>.<ext>.drm
  #
  # The `.drm` marker is an empty file standing in for a protected video, so a
  # rerun counts the item as present and does not queue it.
  class Library
    def initialize(root:, log:)
      @root = Pathname(root)
      @log = log
      @keys = {}
      @mutex = Mutex.new
    end

    # The output root is never created. An absent root on a network volume
    # usually means the volume is not mounted, and creating it would put the run
    # on the boot disk, where the next mount shadows it and the downloads become
    # invisible. Only directories *below* a verified root are created.
    def ensure_root!
      return @root if @root.directory? && @root.writable?

      raise ConfigError, root_problem
    end

    def dir_for(username, source) = @root.join(sanitise(username), source.to_s)

    def path_for(item, username:) = dir_for(username, item.source).join(item.filename)

    def marker_path_for(item, username:) = dir_for(username, item.source).join(item.marker_filename)

    # True when the item is already accounted for -- as a real file or as a
    # protected-video marker.
    def have?(item, username:)
      keys(username, item.source).include?(item.key)
    end

    def size_of(item, username:)
      path_for(item, username:).size
    rescue SystemCallError
      0
    end

    def record(item, username:)
      @mutex.synchronize { (@keys[[sanitise(username), item.source.to_s]] ||= Set.new) << item.key }
    end

    def write_marker(item, username:)
      ensure_root!
      path = marker_path_for(item, username:)
      path.dirname.mkpath
      FileUtils.touch(path)
      record(item, username:)
      path
    end

    # Checked per item rather than once per run: a volume unmounted mid-run
    # must raise, not send the remaining downloads to the boot disk.
    def prepare(item, username:)
      ensure_root!
      path = path_for(item, username:)
      path.dirname.mkpath
      path
    end

    # A `.part` left by an interrupted run is incomplete by definition. Removing
    # them up front keeps "file exists" a reliable completion signal.
    def sweep_partials!
      partials = Pathname.glob(@root.join('**', '*.part*'))
      return 0 if partials.empty?

      partials.each do |path|
        @log.debug("sweeping stale partial #{path}")
        path.delete
      end
      noun = partials.size == 1 ? 'download' : 'downloads'
      @log.warn("discarded #{partials.size} incomplete #{noun} from a previous run")
      partials.size
    end

    def counts
      Pathname.glob(@root.join('*', '*', '*')).each_with_object(Hash.new(0)) do |path, totals|
        next if path.directory?

        totals[path.extname == '.drm' ? :protected : :files] += 1
        totals[:bytes] += path.size unless path.extname == '.drm'
      end
    end

    private

    def root_problem
      return "output_dir #{@root} is not writable" if @root.directory?
      return "output_dir #{@root} exists but is not a directory" if @root.exist?

      "output_dir #{@root} does not exist and will not be created " \
        "(nearest existing path: #{nearest_existing_ancestor}). " \
        'If it lives on a network volume, mount it first.'
    end

    def nearest_existing_ancestor = @root.ascend.find(&:exist?) || Pathname('/')

    # One directory listing per (user, source), cached for the run.
    def keys(username, source)
      cache_key = [sanitise(username), source.to_s]
      @mutex.synchronize do
        @keys[cache_key] ||= scan(dir_for(username, source))
      end
    end

    def scan(dir)
      return Set.new unless dir.directory?

      dir.children.each_with_object(Set.new) do |path, set|
        next if path.directory? || path.extname == '.part'

        key = key_from(path.basename.to_s)
        set << key if key
      end
    end

    # "2026-01-14_1234_5678.mp4" and "...mp4.drm" both yield "1234_5678".
    def key_from(basename)
      parts = basename.split('_', 3)
      return nil unless parts.size == 3

      post_id = parts[1]
      rest = parts[2]
      media_id = rest[/\A\d+/]
      return nil unless post_id.match?(/\A\d+\z/) && media_id

      "#{post_id}_#{media_id}"
    end

    def sanitise(name)
      cleaned = name.to_s.gsub(%r{[/\\:\0]}, '_').strip
      cleaned.empty? ? 'unknown' : cleaned
    end
  end
end
