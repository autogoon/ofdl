# frozen_string_literal: true

require 'optparse'
require 'time'

module OFDL
  # Command line front end.
  class CLI
    # Argument form and one line of description, per command. There is no
    # per-command help: everything a command takes is on the one usage screen,
    # rendered from this and from #fetch_parser.
    COMMANDS = {
      'init' => ['', 'write a starter ~/.ofdl-config.json'],
      'subs' => ['', 'list active subscriptions'],
      'status' => ['', 'check the tools, the library, and that the session authenticates'],
      'fetch' => ['[username ...]', 'download media; with no name, every active subscription']
    }.freeze

    def self.start(argv) = new.run(argv)

    def run(argv)
      global = {}
      parser = global_parser(global)
      parser.order!(argv)

      command = argv.shift
      return usage(parser) if command.nil? || %w[help -h --help].include?(command)
      raise ConfigError, "unknown command #{command.inspect}" unless COMMANDS.key?(command)

      absorb_trailing_globals!(argv, global)
      return usage(parser) if global[:help]

      @log = Logging.new(level: global[:verbose] ? :debug : :info)
      # Verbose output contains the live session verbatim so it can be compared
      # against the browser.
      @log.warn('verbose: output includes live session cookies -- do not paste it publicly') if global[:verbose]
      @config = Config.discover
      # Safe: `command` is checked against COMMANDS above, so this can only ever
      # reach one of the handlers below.
      send("cmd_#{command}", argv)

      0
    rescue Error => e
      warn("\e[31merror:\e[0m #{e.message}")
      1
    rescue Interrupt
      warn("\ninterrupted")
      130
    end

    private

    def session = @session ||= Session.new(config: @config, log: @log)

    # The whole interface on one screen. The fetch options are summarised from
    # the parser that actually reads them, so the two cannot drift.
    def global_parser(options)
      OptionParser.new do |o|
        o.banner = 'usage: ofdl [global options] <command> [options]'
        # Two spaces, matching the commands block, so one column runs down the
        # whole screen rather than one per section.
        o.summary_indent = '  '
        o.summary_width = 24
        o.separator('')
        o.separator('commands:')
        COMMANDS.each do |name, (args, description)|
          o.separator(format('  %-21s %s', "#{name} #{args}".rstrip, description))
        end
        o.separator('')
        o.separator('fetch options:')
        fetch_parser({}).summarize { |line| o.separator(line.chomp) }
        o.separator('')
        o.separator('global options:')
        o.on('-v', '--verbose', 'debug logging') { options[:verbose] = true }
        o.on('--version', 'print version') do
          puts(OFDL::VERSION)
          exit(0)
        end
        o.on('-h', '--help', 'this message')
        USAGE_FOOTER.each { |line| o.separator(line) }
      end
    end

    # Everything below the option lists: how a name is matched, and worked
    # examples of the one command that takes arguments.
    USAGE_FOOTER = [
      '',
      'A creator name may carry a leading @ and is matched without regard to case',
      'against `ofdl subs`. An unknown name is an error, not a silent skip.',
      '',
      'examples:',
      '  ofdl fetch                        every active subscription',
      '  ofdl fetch alice bob              two creators, configured sources',
      '  ofdl fetch alice --sources posts  one creator, one source',
      '  ofdl fetch --since 2026-01-01     everything posted on or after a date'
    ].freeze
    private_constant :USAGE_FOOTER

    # Defines the fetch options; the usage screen renders them, so this carries
    # no banner of its own.
    def fetch_parser(options)
      OptionParser.new do |o|
        o.summary_indent = '  '
        o.summary_width = 24
        o.on('--sources source,...', Array, 'narrow to some of the sources; defaults to all of',
             Config::SOURCES.join(', ')) { options[:sources] = it }
        o.on('--since DATE', 'only media posted on or after DATE (YYYY-MM-DD)') { options[:since] = parse_date(it) }
        o.on('--no-images', 'do not preview downloaded images in the terminal') { options[:images] = false }
      end
    end

    # OptionParser#order! stops at the first non-option, so global flags placed
    # after the subcommand -- `ofdl status -v` -- are still in argv when it
    # returns. Pull them out by hand.
    #
    # --help is taken here rather than left to OptionParser's officious default,
    # which would print the fetch parser's own summary. There is one usage
    # screen, and every spelling of the request reaches it.
    def absorb_trailing_globals!(argv, global)
      argv.delete_if { |arg| %w[-v --verbose].include?(arg) && (global[:verbose] = true) }
      argv.delete_if { |arg| %w[-h --help].include?(arg) && (global[:help] = true) }
    end

    def usage(parser)
      puts(parser)
      0
    end

    # -- commands ------------------------------------------------------------

    def cmd_init(_argv)
      if @config.exist?
        @log.info("config already exists at #{@config.path}")
        return
      end

      path = @config.write_example!
      @log.info("wrote #{path}")
      @log.info('set "output_dir" to a directory that already exists, then run: ofdl status')
      @log.info("every other key is optional; omitted keys follow the app's defaults")
      @log.info('the full list is in the README under Configuration')
    end

    def cmd_subs(_argv)
      rows = subscriptions
      if rows.empty?
        @log.info('no active subscriptions')
        return
      end

      width = rows.map { |r| r['username'].to_s.length }.max
      rows.sort_by { |r| r['username'].to_s.downcase }.each do |row|
        puts(format("%-#{width}s  %s", row['username'], row['id']))
      end
      @log.info("#{rows.size} active #{rows.size == 1 ? 'subscription' : 'subscriptions'}")
    end

    def cmd_fetch(argv)
      options = { sources: @config.sources, since: nil, images: @config.images? }
      fetch_parser(options).parse!(argv)

      unknown = options[:sources] - Config::SOURCES
      raise ConfigError, "unknown sources: #{unknown.join(', ')}" if unknown.any?

      # Resolution runs inside the dashboard: listing subscriptions is several
      # paced API calls, and the screen stays blank until the dashboard starts.
      with_dashboard(options) do |dashboard|
        targets = resolve(argv, options)

        session.library.ensure_root!
        session.library.sweep_partials!
        session.stats.bump(:creators_total, targets.size)

        session.archive(targets:, sources: options[:sources], since: options[:since])

        puts "\n\nAll Done!  Final stats: "
        dashboard.summary.each { puts(it) }
        session.scratch.remove!
      end
    end

    def resolve(argv, options)
      @log.step('resolving subscriptions')
      session.stats.scanning(creator: nil, source: 'subscriptions')

      targets = resolve_targets(argv)
      raise ConfigError, 'no active subscriptions' if targets.empty?

      @log.info("  #{targets.size} to archive: #{targets.map { it[:username] }.join(', ')}")
      @log.info("  sources: #{options[:sources].join(', ')}")
      targets
    end

    # report_session is last: it is the only part that costs a request.
    def cmd_status(_argv)
      report_environment
      report_library
      report_session
    end

    def report_environment
      @log.step('environment')
      @log.info("  config       #{@config.path}")
      @log.info("  chrome       #{Chrome.version || 'NOT FOUND'} (profile #{@config.chrome_profile.inspect})")
      @log.info("  user-agent   #{Chrome.user_agent}#{fingerprint_note}")
      @log.info("  transport    #{session.transport.describe}")
      @log.info("               #{session.transport.version}")
      @log.info("  ffmpeg       #{Remux.available?(@config.ffmpeg) ? 'ok' : "NOT FOUND (#{@config.ffmpeg})"}")
      @log.info("  sips         #{Thumbnail.available? ? 'ok' : 'NOT FOUND (previews disabled)'}")
      @log.info("  terminal     #{terminal_note}")
    end

    def report_library
      @log.step('library')
      @log.info("  output_dir   #{@config.output_dir} #{output_dir_state}")
      return unless @config.output_dir.directory?

      counts = session.library.counts
      creators = @config.output_dir.children.select(&:directory?)
      @log.info("  creators     #{creators.size}")
      @log.info("  files        #{counts[:files].to_i}  (#{human_bytes(counts[:bytes].to_i)})")
      @log.info("  protected    #{counts[:protected].to_i}  DRM, not downloadable")
    end

    def report_session
      @log.step('session')
      jar = session.jar
      @log.info("  cookies      #{jar.values.size} for onlyfans.com (#{jar.values.keys.sort.join(', ')})")
      @log.info("  auth_id      #{jar.auth_id}")
      @log.info("  x-bc         #{truncate(jar.xbc)}")

      rules = session.rules
      @log.info("  rules        static_param #{truncate(rules.static_param)}, " \
                "#{rules.checksum_indexes.size} checksum indexes")

      me = session.api.me
      username = me['username'] || me['name']
      raise ApiError, "authenticated, but /users/me returned no username: #{me.inspect}" unless username

      @log.info("  signed in    @#{username} (id #{me['id']}), #{me['subscribesCount']} subscriptions")
    end

    # -- helpers -------------------------------------------------------------

    def subscriptions
      @subscriptions ||= session.api.subscriptions.to_a.uniq { it['id'] }
    end

    # No names means every active subscription.
    def resolve_targets(names)
      return subscriptions.map { { id: it['id'], username: it['username'] } } if names.empty?

      names.map do |name|
        wanted = name.delete_prefix('@').downcase
        row = subscriptions.find { it['username'].to_s.downcase == wanted }
        raise ConfigError, "not subscribed to #{name.inspect} (run `ofdl subs`)" unless row

        { id: row['id'], username: row['username'] }
      end
    end

    # The dashboard owns the terminal for the duration, so log lines are routed
    # into its scrolling zone. Restoring the terminal has to happen whatever
    # else goes wrong, or the shell prompt is left inside a scroll region.
    def with_dashboard(options)
      dashboard = Dashboard.build(
        stats: session.stats, concurrency: @config.concurrency, io: $stdout,
        images: options[:images], refresh: @config.refresh
      )
      @log.sink = dashboard
      session.preview = dashboard
      dashboard.start
      watch_for_interrupt(dashboard)
      yield self
    ensure
      release_interrupt
      dashboard&.stop
      @log.sink = nil
      session.scratch.remove!
      report_renderer_failure(dashboard)
    end

    # SIGINT reaches curl too -- it is in our process group -- so the transfers
    # are already dead by the time this runs; carrying on would only retry them.
    # The handler itself only writes to a pipe, because a trap context cannot
    # take a mutex, and both the terminal reset and the tidying need one.
    def watch_for_interrupt(dashboard)
      @interrupt = IO.pipe
      @previous_int = trap('INT') do
        @interrupt[1].write_nonblock('!')
      rescue StandardError
        nil
      end
      @interrupt_watcher = Thread.new do
        @interrupt[0].read(1)
        abort_now(dashboard)
      end
    end

    # Nothing partial ever reaches the output directory -- it is all in local
    # scratch, so aborting is a matter of removing one directory.
    def abort_now(dashboard)
      dashboard.stop
      # Printed here as well as on the normal path: nothing else reports what
      # was fetched before the interrupt.
      warn("\n\nInterrupted!  Final stats: ")
      dashboard.summary.each { puts(it) }
      discarded = session.stats.active.size
      session.scratch.remove!
      warn("\nDiscarded #{discarded} partial download#{'s' unless discarded == 1}")
      exit!(130)
    end

    def release_interrupt
      trap('INT', @previous_int || 'DEFAULT')
      @interrupt_watcher&.kill
      @interrupt&.each do |io|
        io.close
      rescue IOError
        nil
      end
    end

    # Prints whatever Dashboard#safe_paint caught, now the screen is back.
    def report_renderer_failure(dashboard)
      return unless dashboard&.error

      warn("\e[33mdashboard stopped drawing:\e[0m #{dashboard.error.class}: #{dashboard.error.message}")
      warn(dashboard.error.backtrace&.first(3)&.join("\n"))
    end

    # The impersonated profile and the User-Agent's Chrome version are allowed
    # to differ; see Chrome.
    def fingerprint_note
      profile = session.transport.target[/\d+/].to_i
      return '' if profile == Chrome.major_version

      " (fingerprint impersonates Chrome #{profile}; curl-impersonate has nothing newer)"
    end

    def output_dir_state
      session.library.ensure_root!
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

    def parse_date(value)
      Time.parse(value)
    rescue ArgumentError
      raise ConfigError, "could not parse date #{value.inspect} (expected YYYY-MM-DD)"
    end

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
