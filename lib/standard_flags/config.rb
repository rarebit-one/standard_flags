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
    # Client context. StandardFlags::Controller reads the calling client from
    # these request headers (`{ platform:, version:, build: }` => header
    # name) unless `read_client_headers` is false; a platform outside
    # `client_platforms` is dropped.
    attr_accessor :client_headers, :client_platforms, :read_client_headers
    # The client audiences this app serves (see StandardFlags::Audience):
    # an Array of names, or a Hash of name => `{ public:, unit: }`. nil (the
    # default) means every audience a flag exposes to, none of them public.
    # When set, every `expose:` and tombstone `serve:` audience must be
    # declared here, or the registry refuses to build.
    attr_reader :audiences
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
    # app-defined segment. nil skips segment conditions. Through the
    # OpenFeature provider the context's actors are unit keys (strings), not
    # records, so a resolver used there must handle both.
    attr_accessor :segment_resolver

    # The write path's policy hook: `call(actor, scope, key)` is truthy when
    # `actor` may use `scope` ("flags:read", "flags:write" or "flags:ramp")
    # on `key` (a flag key Symbol, or "cohort:<key>"). The default allows
    # StandardFlags::Actor.system actors and nobody else.
    attr_reader :authorize
    # `call` returns the actor for an operation called without `actor:`.
    # Defaults to `Current.user` when the app defines Current with a `user`.
    attr_reader :actor_resolver
    # Write-time limits (never checked on read): live members per rule or
    # cohort, unit keys per operation, cohorts attached to one rule, and the
    # size of a rule's conditions in bytes of JSON.
    attr_accessor :max_members, :max_keys_per_operation, :max_cohorts_per_rule, :max_conditions_bytes
    # Seconds a removed or expired membership is kept (so it can be
    # restored) before `flags:purge` / StandardFlags::PurgeJob deletes it.
    attr_accessor :membership_retention
    # Whether each process records which flags it evaluated, writing
    # standard_flags_rules.last_evaluated_at for `flags:stale`, and at most
    # how often (seconds) it writes.
    attr_accessor :track_evaluations, :evaluation_tracking_interval
    # Whether each process counts evaluations of compat flags that declare
    # `until_clients:` (hits and the oldest client version per platform),
    # writing them to standard_flags_compat_stats at most every
    # `evaluation_tracking_interval` seconds. Off by default; needs runtime
    # rules and the compat stats migration.
    attr_accessor :track_compat
    # The client registry's store ceiling: a lookup (`call(client_app)` =>
    # version) asked about iOS clients, or a Hash of client name => lookup.
    # nil uses each client's declared `available:` alone. See
    # StandardFlags::Stores.
    attr_accessor :client_store_lookup
    # When true, `requires_client_version` also answers 426 to a request
    # whose platform or version is unknown. Off by default: an unknown build
    # is never forced to upgrade.
    attr_accessor :require_client_version

    DEFAULT_CLIENT_HEADERS = { platform: "X-Client-Platform", version: "X-Client-Version", build: "X-Client-Build" }.freeze
    DEFAULT_CLIENT_PLATFORMS = %w[android ios web desktop].freeze
    DEFAULT_AUTHORIZE = ->(actor, _scope, _key) { actor.is_a?(Actor) && actor.system? }
    DEFAULT_ACTOR_RESOLVER = -> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }

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
      @client_headers = DEFAULT_CLIENT_HEADERS
      @client_platforms = DEFAULT_CLIENT_PLATFORMS
      @read_client_headers = true
      @audiences = nil
      @runtime_rules = false
      @refresh_interval = 5
      @runtime_store = nil
      @segment_resolver = nil
      @error_reporter = nil
      @authorize = DEFAULT_AUTHORIZE
      @actor_resolver = DEFAULT_ACTOR_RESOLVER
      @max_members = 10_000
      @max_keys_per_operation = 1_000
      @max_cohorts_per_rule = 20
      @max_conditions_bytes = 64 * 1024
      @membership_retention = 90 * 86_400
      @track_evaluations = true
      @evaluation_tracking_interval = 3_600
      @track_compat = false
      @client_store_lookup = nil
      @require_client_version = false
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

    def audiences=(value)
      @audiences = Audience.normalize(value)
    end

    def error_reporter=(reporter)
      raise ArgumentError, "error_reporter must respond to call(error, context)" unless reporter.nil? || reporter.respond_to?(:call)

      @error_reporter = reporter
    end

    def authorize=(policy)
      raise ArgumentError, "authorize must respond to call(actor, scope, key)" unless policy.respond_to?(:call)

      @authorize = policy
    end

    def actor_resolver=(resolver)
      raise ArgumentError, "actor_resolver must respond to call" unless resolver.nil? || resolver.respond_to?(:call)

      @actor_resolver = resolver
    end

    # Adds a subscriber that responds to `call(event_name, payload)` for every
    # `*.standard_flags` event.

    def add_notifier(notifier)
      raise ArgumentError, "notifier must respond to call(event_name, payload)" unless notifier.respond_to?(:call)

      @extra_notifiers << notifier unless @extra_notifiers.include?(notifier)
      notifier
    end
  end
end
