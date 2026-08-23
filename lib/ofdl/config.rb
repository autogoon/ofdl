# frozen_string_literal: true

require 'json'

module OFDL
  # There is no database and no hidden state directory: this JSON file and the
  # output tree hold all persistent state.
  class Config
    SOURCES = %w[posts messages stories highlights paid archived].freeze

    # output_dir is not here. It is the one key with no defensible default: an
    # invented root would be silently created on the boot disk the first time a
    # network mount was missing, which is the failure `ensure_root!` exists to
    # prevent. It is required, and #output_dir raises until it is set.
    DEFAULTS = {
      'chrome_profile' => 'Default',
      'concurrency' => 4,
      'requests_per_second' => 2.0,
      'rules_url' => 'https://r2.hlsdownloader.com/win32/dynamicRules.json',
      'sources' => SOURCES,
      'skip_protected' => true,
      'mark_protected' => true,
      'ffmpeg' => 'ffmpeg',
      'curl_impersonate' => 'curl-impersonate',
      'images' => true,
      'refresh' => 0.05
    }.freeze

    DEFAULT_PATH = '~/.ofdl-config.json'

    attr_reader :path, :data

    # Not a walk up from the working directory: the config is per-user, so the
    # working directory cannot change which OnlyFans account gets archived.
    def self.discover(path: DEFAULT_PATH) = new(Pathname(path).expand_path)

    # An absent file is not an error here: `ofdl init` has to run against one,
    # and every other command fails on #output_dir with a message that says so.
    def initialize(path)
      @path = Pathname(path)
      @data = DEFAULTS.merge(read)
      validate!
    end

    def exist? = @path.file?

    def output_dir
      value = @data['output_dir']
      if value.to_s.empty?
        raise ConfigError, "no config at #{@path} -- run `ofdl init`" unless @path.file?

        raise ConfigError, "set \"output_dir\" in #{@path} to a directory that already exists"
      end

      Pathname(value).expand_path
    end

    def chrome_profile = @data.fetch('chrome_profile')

    def concurrency = Integer(@data.fetch('concurrency'))

    def requests_per_second = Float(@data.fetch('requests_per_second'))

    def curl_impersonate = @data.fetch('curl_impersonate')

    # Dashboard. `images` previews each downloaded photo in the terminal, in the
    # slice belonging to the worker that fetched it; `refresh` is how often the
    # panels repaint.
    def images? = @data.fetch('images') != false

    def refresh = Float(@data.fetch('refresh'))

    def rules_url = @data.fetch('rules_url')

    def rules_file = @data['rules_file']&.then { Pathname(it).expand_path }

    # Refetched only when OnlyFans rejects a signature; see RulesSource.
    def cached_rules = @data['rules']

    def store_rules!(payload)
      return false unless @path.file?

      raw = JSON.parse(@path.read)
      raw['rules'] = payload
      tmp = @path.sub_ext('.json.part')
      tmp.write("#{JSON.pretty_generate(raw)}\n")
      tmp.rename(@path)
      @data = DEFAULTS.merge(raw)
      true
    rescue JSON::ParserError, SystemCallError
      false
    end

    def sources = Array(@data.fetch('sources')).map(&:to_s)

    def skip_protected? = @data.fetch('skip_protected') != false

    def mark_protected? = @data.fetch('mark_protected') != false

    def ffmpeg = @data.fetch('ffmpeg')

    # Not a default: a value that cannot work, so a config left unedited fails
    # at `ofdl status` rather than archiving into an invented directory.
    OUTPUT_DIR_PLACEHOLDER = '/path/to/your/library'

    # Writes the one required key, not the whole of DEFAULTS. A key written here
    # is pinned at the value it held the day `ofdl init` ran: the merge in
    # #initialize finds it present and never reaches the app's default again, so
    # a default corrected later would reach new users only. An absent key is the
    # mechanism by which a config tracks the app.
    def write_example!
      @path.dirname.mkpath
      @path.write("#{JSON.pretty_generate({ 'output_dir' => OUTPUT_DIR_PLACEHOLDER })}\n")
      @path
    end

    private

    def read
      return {} unless @path.file?

      parsed = JSON.parse(@path.read)
      raise ConfigError, "#{@path} must contain a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise ConfigError, "#{@path} is not valid JSON: #{e.message}"
    end

    def validate!
      unknown = sources - SOURCES
      raise ConfigError, "unknown sources: #{unknown.join(', ')} (known: #{SOURCES.join(', ')})" if unknown.any?
      raise ConfigError, 'concurrency must be >= 1' if concurrency < 1
      raise ConfigError, 'requests_per_second must be > 0' unless requests_per_second.positive?
      raise ConfigError, 'refresh must be > 0' unless refresh.positive?
    end
  end
end
