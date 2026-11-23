module StandardFlags
  # Runtime settings, set from `config/initializers/standard_flags.rb`:
  #
  #   StandardFlags.configure do |config|
  #     config.evaluate_sample_rate = 0.01
  #   end
  #
  # Flags themselves are declared in config/flags.rb with StandardFlags.define.
  class Config
    # Fraction (0.0..1.0) of evaluations that emit `evaluate.standard_flags`.
    attr_accessor :evaluate_sample_rate
    # Logger for the Logger subscriber; defaults to Rails.logger.
    attr_accessor :logger
    # Off by default: Rails.error already carries rejected and forbidden pins
    # to an error tracker wired to it. Turn on only when it isn't, or you get
    # each warning twice.
    attr_accessor :sentry_enabled
    # Sentry::Metrics counters, when sentry-ruby is loaded.
    attr_accessor :metrics_enabled
    attr_accessor :metric_prefix
    # The registry file loaded on boot and on every code reload.
    attr_accessor :registry_path
    # Where `flags:refs` looks for flag reads.
    attr_accessor :refs_paths
    attr_accessor :refs_extensions
    # Outputs of `standard_flags:manifest` and `standard_flags:typescript`.
    attr_accessor :manifest_path
    attr_accessor :typescript_path
    # `call(controller, denial)` replaces the default `requires_flag` response.
    attr_accessor :controller_responder
    # Whose wire name `requires_flag` reports in `meta.feature`.
    attr_accessor :default_audience
    # Runtime rules (rules stored in the app's database, between the ENV pin
    # and the code default). Off by default; when off, nothing touches a
    # database and ActiveRecord is never loaded. Turn on only after running
    # `bin/rails g standard_flags:migrations` and migrating.
    attr_accessor :runtime_rules
    # Seconds between checks of the stored revision. Each check is one query;
    # rules reload only when the revision has moved.
    attr_accessor :refresh_interval
    # Where runtime rules are read from. nil means the ActiveRecord store;
    # pass a StandardFlags::Runtime::MemoryStore (or any Store) to run
    # without a database.
    attr_accessor :runtime_store
    # `call(error, context)` replaces Rails.error for every report the gem
    # makes (rejected and forbidden pins, unknown flags, evaluation errors,
    # invalid runtime rules, runtime store failures). nil uses Rails.error;
    # a reporter that raises falls back to it.
    attr_reader :error_reporter
    # `call(segment_name, context)` answers whether the context belongs to an
    # app-defined segment. nil skips segment conditions.
    attr_accessor :segment_resolver

    attr_writer :strict, :env_source
    attr_reader :extra_notifiers

    def initialize
      @evaluate_sample_rate = 0.0
      @logger = nil
      @sentry_enabled = false
      @metrics_enabled = true
      @metric_prefix = "standard_flags"
      @registry_path = "config/flags.rb"
      @refs_paths = %w[app lib config]
      @refs_extensions = %w[rb erb rake haml slim jbuilder]
      @manifest_path = "config/flags.manifest.json"
      @typescript_path = "app/javascript/types/standard_flags.d.ts"
      @controller_responder = nil
      @default_audience = :web
      @runtime_rules = false
      @refresh_interval = 5
      @runtime_store = nil
      @segment_resolver = nil
      @error_reporter = nil
      @strict = nil
      @env_source = nil
      @extra_notifiers = []
    end

    # Unknown keys and kind mismatches raise when strict. Defaults to true
    # everywhere except a production Rails process.
    def strict?
      return @strict unless @strict.nil?

      !(defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production?)
    end

    # Where ENV pins are read from. Anything that responds to `[]`.
    def env_source
      @env_source || ENV
    end

    # Adds a subscriber that responds to `call(event_name, payload)` for every
    # `*.standard_flags` event.
    def error_reporter=(reporter)
      raise ArgumentError, "error_reporter must respond to call(error, context)" unless reporter.nil? || reporter.respond_to?(:call)

      @error_reporter = reporter
    end

    def add_notifier(notifier)
      raise ArgumentError, "notifier must respond to call(event_name, payload)" unless notifier.respond_to?(:call)

      @extra_notifiers << notifier unless @extra_notifiers.include?(notifier)
      notifier
    end
  end
end
