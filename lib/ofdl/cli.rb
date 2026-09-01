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
      'fetch' => ['[creator ...]', 'download media; with no name, every active subscription']
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
        # whole screen rather than one per section. 26 is the width `--post-types
        # type,...` needs to keep its description on the same line.
        o.summary_indent = '  '
        o.summary_width = 26
        o.separator('')
        o.separator('commands:')
        COMMANDS.each do |name, (args, description)|
          o.separator(format('  %-21s %s', "#{name} #{args}".rstrip, description))
        end
        option_sections(o)
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

    # One section per command that takes options, each rendered from the parser
    # that reads them, so an option cannot appear in one and not the other.
    def option_sections(parser)
      { 'subs' => subs_parser({}), 'status' => status_parser({}), 'fetch' => fetch_parser({}) }
        .each do |command, sub|
          parser.separator('')
          parser.separator("#{command} options:")
          sub.summarize { |line| parser.separator(line.chomp) }
        end
    end

    # Everything below the option lists: how a name is matched, and worked
    # examples of the one command that takes arguments.
    USAGE_FOOTER = [
      '',
      'A creator name may carry the app it is on -- onlyfans/alice, of/alice -- and',
      'without one means onlyfans. It may carry a leading @ and is matched without',
      'regard to case against `ofdl subs`. An unknown name is an error, not a silent',
      'skip.',
      '',
      'examples:',
      '  ofdl fetch                           every active subscription',
      '  ofdl fetch alice of/bob              two creators, configured post types',
      '  ofdl fetch alice --post-types posts  one creator, one post type',
      '  ofdl fetch --source of               every creator on one app',
      '  ofdl fetch --since 2026-01-01        everything posted on or after a date'
    ].freeze
    private_constant :USAGE_FOOTER

    # Off by default: Library#counts stats every file under output_dir, which on
    # a mounted share is one network round trip each.
    def status_parser(options)
      OptionParser.new do |o|
        o.summary_indent = '  '
        o.summary_width = 26
        o.on('--library-stats', 'count the files and bytes in output_dir') { options[:library_stats] = true }
      end
    end

    # `subs` and `fetch` both take it, so it is defined once and added to both.
    def source_option(parser, options)
      parser.on('--source app,...', Array, 'narrow to some of the apps; defaults to all of',
                Source::ALL.join(', ')) { options[:sources] = resolve_sources(it) }
    end

    def resolve_sources(names)
      names.map do |name|
        Source.resolve(name) or
          raise ConfigError, "unknown app #{name.inspect} (known: #{Source::ALL.join(', ')})"
      end
    end

    def subs_parser(options)
      OptionParser.new do |o|
        o.summary_indent = '  '
        o.summary_width = 26
        source_option(o, options)
      end
    end

    # Defines the fetch options; the usage screen renders them, so this carries
    # no banner of its own.
    def fetch_parser(options)
      OptionParser.new do |o|
        o.summary_indent = '  '
        o.summary_width = 26
        source_option(o, options)
        o.on('--post-types type,...', Array, 'narrow to some of the post types; defaults to all of',
             Config::POST_TYPES.join(', ')) { options[:post_types] = it }
        o.on('--since DATE', 'only media posted on or after DATE (YYYY-MM-DD)') { options[:since] = parse_date(it) }
        o.on('--include-ads', 'keep posts that advertise another creator') { options[:skip_ads] = false }
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

    # Each row is printed in the form `fetch` takes, so a name can be copied
    # from here straight onto a command line.
    def cmd_subs(argv)
      options = { sources: Source::ALL }
      subs_parser(options).parse!(argv)

      rows = resolve_targets([], options[:sources])
      if rows.empty?
        @log.info('no active subscriptions')
        return
      end

      names = rows.to_h { [it, "#{it[:source]}/#{it[:username]}"] }
      width = names.values.map(&:length).max
      rows.sort_by { names[it].downcase }.each { puts(format("%-#{width}s  %s", names[it], it[:id])) }
      @log.info("#{rows.size} active #{rows.size == 1 ? 'subscription' : 'subscriptions'}")
    end

    def cmd_fetch(argv)
      options = { sources: Source::ALL, post_types: @config.post_types, since: nil,
                  images: @config.images?, skip_ads: @config.skip_ads? }
      fetch_parser(options).parse!(argv)

      unknown = options[:post_types] - Config::POST_TYPES
      raise ConfigError, "unknown post types: #{unknown.join(', ')}" if unknown.any?

      # Resolution runs inside the dashboard: listing subscriptions is several
      # paced API calls, and the screen stays blank until the dashboard starts.
      with_dashboard(options) do |dashboard|
        session.library.ensure_root!
        session.library.sweep_partials!
        # Started here and left running. Scoping the walk needs only the names,
        # not the ids `resolve` looks up, so the walk can start before the
        # subscription lookup; the walk costs no request, so it overlaps that
        # lookup and the listing that follows. The producer waits on the walk a
        # creator at a time; see Session#count_library.
        session.count_library(only: named_creators(argv))

        targets = resolve(argv, options)
        session.stats.bump(:creators_total, targets.size)

        session.archive(targets:, post_types: options[:post_types], since: options[:since],
                        skip_ads: options[:skip_ads])

        dashboard.stop

        puts "\n\nAll Done!  Final stats: "
        dashboard.summary.each { puts(it) }
        report_gaps
        session.scratch.remove!
      end
    end

    # The creators named on the command line, as targets without an id, or `nil`
    # when no names were given. `nil` leaves the walk unscoped. Case is folded
    # by Library#tally, not here.
    def named_creators(names)
      return nil if names.empty?

      names.map { split_name(it).then { |source, username| { source:, username: } } }
    end

    # `alice`, `onlyfans/alice`, `of/@Alice`. Returns [source, username]. The @
    # belongs to the creator name, so it comes off after the prefix.
    #
    # An unresolvable prefix raises rather than being taken as part of a
    # username: a name that reached the subscription lookup with a slash in it
    # could only ever fail to match, and would say so in terms of the wrong
    # thing.
    def split_name(name)
      prefix, rest = name.split('/', 2)
      return [Source::DEFAULT, name.delete_prefix('@')] if rest.nil?

      source = Source.resolve(prefix) or
        raise ConfigError, "unknown app #{prefix.inspect} in #{name.inspect} (known: #{Source::ALL.join(', ')})"

      [source, rest.delete_prefix('@')]
    end

    # Repeated below the panel because the inline warning scrolls away during a
    # long run; see Session#note_gap.
    def report_gaps
      gaps = session.gaps
      return if gaps.empty?

      puts("\n\e[33m--since did not reach back far enough for:\e[0m")
      gaps.each { puts("  #{it}") }
      puts('Rerun those with an earlier --since, or with none, to fill the gap.')
    end

    def resolve(argv, options)
      @log.step('resolving subscriptions')
      session.stats.scanning(creator: nil, step: 'subscriptions')

      targets = session.in_walk_order(resolve_targets(argv, options[:sources]))
      raise ConfigError, 'no active subscriptions' if targets.empty?

      @log.info("  #{targets.size} to archive: #{targets.map { "#{it[:source]}/#{it[:username]}" }.join(', ')}")
      @log.info("  post types: #{options[:post_types].join(', ')}")
      targets
    end

    # report_session is last: it is the only part that costs a request.
    def cmd_status(argv)
      options = { library_stats: false }
      status_parser(options).parse!(argv)

      report_environment
      report_library(stats: options[:library_stats])
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

    def report_library(stats:)
      @log.step('library')
      @log.info("  output_dir   #{@config.output_dir} #{output_dir_state}")
      return unless @config.output_dir.directory?
      return @log.info('  use --library-stats to get full stats of your library') unless stats

      counts = session.library.counts
      # <output_dir>/<source>/<creator>/, the layout at the top of Library.
      creators = @config.output_dir.glob('*/*').count(&:directory?)
      @log.info("  creators     #{creators}")
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

    # No names means every creator on every app the run covers.
    def resolve_targets(names, sources)
      return sources.flat_map { creators_on(it) } if names.empty?

      names.map { resolve_name(it, sources) }
    end

    def creators_on(source)
      raise ConfigError, "no adapter for #{source}" unless source == Source::ONLYFANS

      subscriptions.map { { source:, id: it['id'], username: it['username'] } }
    end

    def resolve_name(name, sources)
      source, username = split_name(name)
      unless sources.include?(source)
        covering = sources.empty? ? 'nothing' : sources.join(', ')
        raise ConfigError, "#{name.inspect} is on #{source}, which this run does not cover (covering: #{covering})"
      end

      row = subscriptions.find { it['username'].to_s.downcase == username.downcase }
      raise ConfigError, "not subscribed to #{username.inspect} on #{source} (run `ofdl subs`)" unless row

      { source:, id: row['id'], username: row['username'] }
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
      yield dashboard
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
