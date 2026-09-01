# frozen_string_literal: true

module OFDL
  # What `ofdl status` prints: the tools it found, the library, and whether the
  # session authenticates.
  #
  # In that order, because only the last costs a request -- everything wrong
  # with the setup is on screen before the network is touched.
  class StatusReport
    def initialize(config:, log:, session:)
      @config = config
      @log = log
      @session = session
    end

    def call(library_stats: false, sources: Source::ALL)
      environment
      library(stats: library_stats)
      sources.each { sign_in(it) }
    end

    def environment
      @log.step('environment')
      line('config', @config.path)
      line('chrome', "#{Chrome.version || 'NOT FOUND'} (profile #{@config.chrome_profile.inspect})")
      line('user-agent', "#{Chrome.user_agent}#{fingerprint_note}")
      line('transport', @session.transport.describe)
      line('', @session.transport.version)
      line('ffmpeg', Remux.available?(@config.ffmpeg) ? 'ok' : "NOT FOUND (#{@config.ffmpeg})")
      line('sips', Thumbnail.available? ? 'ok' : 'NOT FOUND (previews disabled)')
      line('terminal', terminal_note)
    end

    def library(stats: false)
      @log.step('library')
      line('output_dir', "#{@config.output_dir} #{output_dir_state}")
      return unless @config.output_dir.directory?
      return @log.info('  use --library-stats to get full stats of your library') unless stats

      counts = @session.library.counts
      line('creators', creator_count)
      line('files', "#{counts[:files].to_i}  (#{Display.humanize(counts[:bytes].to_i)})")
      line('protected', "#{counts[:protected].to_i}  DRM, not downloadable")
    end

    # One section per app, each headed by the app's name, because a run can
    # cover more than one and each has its own session to prove.
    def sign_in(key)
      @log.step(key)
      @session.adapter_for(key).status_lines.each { |label, value| line(label, value) }
    end

    private

    # The label column, so an adapter supplying a pair need not know its width.
    def line(label, value) = @log.info(format('  %-13s%s', label, value))

    # <output_dir>/<source>/<creator>/, the layout at the top of Library, so a
    # source directory on its own is not a creator.
    def creator_count = @config.output_dir.glob('*/*').count(&:directory?)

    # The impersonated profile and the User-Agent's Chrome version are allowed
    # to differ; see Chrome.
    def fingerprint_note
      profile = @session.transport.target[/\d+/].to_i
      return '' if profile == Chrome.major_version

      " (fingerprint impersonates Chrome #{profile}; curl-impersonate has nothing newer)"
    end

    def output_dir_state
      @session.library.ensure_root!
      '(ok)'
    rescue ConfigError => e
      "\e[31m-- #{e.message}\e[0m"
    end

    # The cell size decides what shape the preview is cropped to; see
    # Dashboard#thumbnail_box.
    def terminal_note
      cell = Display.cell_size($stdout)
      return 'cell size not reported -- previews use an estimate' unless cell

      rows, columns = $stdout.winsize
      "#{columns}x#{rows} cells, #{cell[0]}x#{cell[1]} px each"
    rescue StandardError
      'not a terminal'
    end
  end
end
