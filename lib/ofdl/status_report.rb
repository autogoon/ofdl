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

    def call(library_stats: false)
      environment
      library(stats: library_stats)
      session
    end

    def environment
      @log.step('environment')
      @log.info("  config       #{@config.path}")
      @log.info("  chrome       #{Chrome.version || 'NOT FOUND'} (profile #{@config.chrome_profile.inspect})")
      @log.info("  user-agent   #{Chrome.user_agent}#{fingerprint_note}")
      @log.info("  transport    #{@session.transport.describe}")
      @log.info("               #{@session.transport.version}")
      @log.info("  ffmpeg       #{Remux.available?(@config.ffmpeg) ? 'ok' : "NOT FOUND (#{@config.ffmpeg})"}")
      @log.info("  sips         #{Thumbnail.available? ? 'ok' : 'NOT FOUND (previews disabled)'}")
      @log.info("  terminal     #{terminal_note}")
    end

    def library(stats: false)
      @log.step('library')
      @log.info("  output_dir   #{@config.output_dir} #{output_dir_state}")
      return unless @config.output_dir.directory?
      return @log.info('  use --library-stats to get full stats of your library') unless stats

      counts = @session.library.counts
      @log.info("  creators     #{creator_count}")
      @log.info("  files        #{counts[:files].to_i}  (#{human_bytes(counts[:bytes].to_i)})")
      @log.info("  protected    #{counts[:protected].to_i}  DRM, not downloadable")
    end

    def session
      @log.step('session')
      jar = @session.jar
      @log.info("  cookies      #{jar.values.size} for onlyfans.com (#{jar.values.keys.sort.join(', ')})")
      @log.info("  auth_id      #{jar.auth_id}")
      @log.info("  x-bc         #{truncate(jar.xbc)}")

      rules = @session.rules
      @log.info("  rules        static_param #{truncate(rules.static_param)}, " \
                "#{rules.checksum_indexes.size} checksum indexes")

      me = @session.api.me
      username = me['username'] || me['name']
      raise ApiError, "authenticated, but /users/me returned no username: #{me.inspect}" unless username

      @log.info("  signed in    @#{username} (id #{me['id']}), #{me['subscribesCount']} subscriptions")
    end

    private

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

    # Session material is printed as a prefix: enough to compare against the
    # browser, not enough to reuse.
    def truncate(value, length = 24)
      string = value.to_s
      string.length > length ? "#{string[0, length]}..." : string
    end

    def human_bytes(bytes)
      units = %w[B KB MB GB TB]
      size = bytes.to_f
      units.each_with_index do |name, index|
        return format(index.zero? ? '%d %s' : '%.1f %s', size, name) if size < 1024 || index == units.size - 1

        size /= 1024
      end
    end
  end
end
