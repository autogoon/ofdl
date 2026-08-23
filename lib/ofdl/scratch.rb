# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module OFDL
  # Local working space for downloads in progress.
  #
  # Nothing reaches its final name in the output directory until it is complete.
  # curl writes here, on local disk, and the finished file is copied across in
  # one go.
  #
  # Where the output directory is a mounted share, writing a file
  # incrementally is slow, and the attribute cache is invalidated by each write,
  # so every progress check is a network round trip. A stat() here does not leave
  # the machine, so the dashboard can poll freely.
  #
  # One directory per run, removed when the run ends.
  class Scratch
    def initialize(root: nil)
      @root = Pathname(root || Dir.mktmpdir('ofdl-'))
    end

    attr_reader :root

    def path_for(item) = @root.join("#{item.key}.#{item.extension}")

    def headers_for(item) = @root.join("#{item.key}.headers")

    # A rename cannot cross filesystems, so moving straight from here would be a
    # copy, and an interrupted copy leaves a short file under the final name that
    # the next run takes for a completed download. Renaming within the
    # destination is atomic, so a file that exists is always whole.
    def publish(source, destination)
      staged = Pathname("#{destination}.part")
      FileUtils.cp(source, staged)
      staged.rename(destination)
      destination.size
    end

    def clear(*paths)
      paths.each do |path|
        next unless path

        Pathname(path).delete
      rescue SystemCallError
        nil
      end
    end

    def remove!
      FileUtils.remove_entry(@root)
    rescue SystemCallError
      nil
    end
  end
end
