# frozen_string_literal: true

require 'fileutils'

module OFDL
  # The output tree is the only record of what has been downloaded. There is no
  # index to fall out of sync with the disk: a file that exists was completed,
  # because completion is an atomic rename from `.part` into place (see
  # Scratch#publish).
  #
  #   <output_dir>/<username>/<post_type>/<date>_<post_id>_<media_id>.<ext>
  #   <output_dir>/<username>/<post_type>/<date>_<post_id>_<media_id>.<ext>.drm
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

    def dir_for(username, post_type) = @root.join(sanitise(username), post_type.to_s)

    def path_for(item, username:) = dir_for(username, item.post_type).join(item.filename)

    def marker_path_for(item, username:) = dir_for(username, item.post_type).join(item.marker_filename)

    # True when the item is already accounted for -- as a real file or as a
    # protected-video marker.
    def have?(item, username:)
      keys(username, item.post_type).include?(item.key)
    end

    def size_of(item, username:)
      path_for(item, username:).size
    rescue SystemCallError
      0
    end

    # Returns [files, bytes]. With `only` absent, reads every creator directory
    # and every post type under each creator directory. `only` is creator names
    # as typed; tally folds each name with `walk_key`, so the case a name is
    # given in need not match the directory's, and reads only those creators'
    # directories. The count never depends on the post types a run names, or on
    # `--since`. See Session#count_library.
    #
    # The walk makes the same per-directory listings `have?` makes one at a
    # time, so the cache the walk fills is the one a run's presence checks then
    # read.
    #
    # A `.drm` marker counts as a file and adds no bytes: the protected video
    # was never downloaded.
    #
    # Each file is yielded as it is read, so a counter fed from here climbs
    # while the tree is walked rather than stepping once per directory.
    #
    # Creators are walked in `walk_key` order and `on_creator` is called with
    # each key as it is finished, so a caller running alongside tally can start
    # on a creator the walk has passed. Session#produce is that caller, and
    # orders its targets by the same key.
    def tally(only: nil, on_creator: nil, &progress)
      wanted = only&.to_set { walk_key(it) }
      files = bytes = 0

      creator_groups(wanted).each do |group|
        group.each do |creator|
          counted, size = tally_creator(creator, &progress)
          files += counted
          bytes += size
        end
        on_creator&.call(walk_key(group.last.basename.to_s))
      end

      [files, bytes]
    end

    def record(item, username:)
      @mutex.synchronize { (@keys[[sanitise(username), item.post_type.to_s]] ||= Set.new) << item.key }
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

    # The directory a username maps to.
    def sanitise(name)
      cleaned = name.to_s.gsub(%r{[/\\:\0]}, '_').strip
      cleaned.empty? ? 'unknown' : cleaned
    end

    # The key `tally`'s walk and a caller waiting on it both order by. It folds
    # case because a case-insensitive filesystem keeps the directory `alice`
    # after the username became `Alice`, and two keys mean a waiter released
    # before its directory has been read; see Watermark.
    def walk_key(name) = sanitise(name).downcase

    private

    def root_problem
      return "output_dir #{@root} is not writable" if @root.directory?
      return "output_dir #{@root} exists but is not a directory" if @root.exist?

      "output_dir #{@root} does not exist and will not be created " \
        "(nearest existing path: #{nearest_existing_ancestor}). " \
        'If it lives on a network volume, mount it first.'
    end

    def nearest_existing_ancestor = @root.ascend.find(&:exist?) || Pathname('/')

    # One directory listing per (user, post type), cached for the run.
    def keys(username, post_type)
      cache(username, post_type) { key_set(media_files(dir_for(username, post_type))) }
    end

    def cache(username, post_type)
      @mutex.synchronize { @keys[[sanitise(username), post_type.to_s]] ||= yield }
    end

    # <root>/<username>/<post_type>/, the layout at the top of this class. A
    # directory name is a sanitised username, which is what the cache is keyed
    # by. Sorted, so a walk of the tree has an order others can wait on.
    def creator_dirs(only)
      return [] unless @root.directory?

      dirs = @root.children.select(&:directory?)
      dirs = dirs.select { only.include?(walk_key(it.basename.to_s)) } if only
      dirs.sort_by { walk_key(it.basename.to_s) }
    end

    # Directories sharing a walk key -- `Alice` beside `alice`, which only a
    # case-sensitive filesystem allows -- form one group, so the key reaches
    # `on_creator` once every directory under it has been read.
    def creator_groups(only)
      creator_dirs(only).chunk_while { |a, b| walk_key(a.basename.to_s) == walk_key(b.basename.to_s) }
    end

    # The cache key stays the directory's own name: folding it would share one
    # key set between `Alice/` and `alice/`, and whether those are one
    # directory or two is a property of the filesystem this cannot read.
    def tally_creator(creator)
      files = bytes = 0

      post_type_dirs(creator).each do |dir|
        paths = media_files(dir)
        cache(creator.basename.to_s, dir.basename.to_s) { key_set(paths) }
        paths.each do |path|
          size = path.extname == '.drm' ? 0 : path.size
          files += 1
          bytes += size
          yield(1, size) if block_given?
        end
      end

      [files, bytes]
    end

    def post_type_dirs(creator) = creator.children.select(&:directory?)

    # What counts as present in one (creator, post type) directory: a downloaded
    # file or a `.drm` marker, never a `.part`.
    def media_files(dir)
      return [] unless dir.directory?

      dir.children.reject do |path|
        path.directory? || path.extname == '.part' || key_from(path.basename.to_s).nil?
      end
    end

    def key_set(paths)
      paths.each_with_object(Set.new) { |path, set| set << key_from(path.basename.to_s) }
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
  end
end
