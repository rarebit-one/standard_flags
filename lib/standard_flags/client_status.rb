module StandardFlags
  # Whether the calling client should, or must, upgrade, from the client
  # registry (`client` in config/flags.rb; see StandardFlags::ClientApp):
  #
  #   StandardFlags::ClientStatus.for(client).to_h
  #   # => { "status" => "upgrade_recommended", "platform" => "android", "version" => "0.3.2",
  #   #      "min_version" => "0.4.0", "recommended" => "0.5.0", "enforce_at" => "2026-12-08",
  #   #      "store_url" => "https://example.com/app" }
  #
  # * `unknown`: no platform, a platform this app doesn't recognise, or no
  #   usable version. An unknown build is never told to upgrade.
  # * `upgrade_required`: the version is below the enforced minimum and
  #   enforcement has started (on `enforce_at`, which is `since` plus the
  #   grace window).
  # * `upgrade_recommended`: below the minimum during its grace window (with
  #   `enforce_at`), or below `recommended`.
  # * `ok`: anything else, including a recognised platform with no client
  #   declared for it.
  #
  # `min_version` and `recommended` are what applies after the store
  # ceiling: never above the newest version known to be in the store.
  # `enforce_at` is set whenever the version is below that minimum (a date
  # still to come during the grace window, a past one once enforced). Dates
  # are UTC.
  #
  # StandardFlags::ClientStatus::Controller serves it as `GET
  # /client/status`; StandardFlags::Controller's `requires_client_version`
  # answers 426 when it is `upgrade_required`.
  module ClientStatus
    autoload :Controller, "standard_flags/client_status/controller"

    STATUSES = %w[ok upgrade_recommended upgrade_required unknown].freeze

    Result = Data.define(:status, :platform, :version, :min_version, :recommended, :enforce_at, :store_url, :client_app) do
      def upgrade_required?
        status == "upgrade_required"
      end

      def unknown?
        status == "unknown"
      end

      # The status payload, with String keys; absent values are nil.
      def to_h
        { "status" => status, "platform" => platform, "version" => version&.to_s, "min_version" => min_version&.to_s,
          "recommended" => recommended&.to_s, "enforce_at" => enforce_at&.iso8601, "store_url" => store_url }
      end
    end

    module_function

    # The status of `client` (a Client or a Hash) against the clients
    # declared in `group:` (nil is the default group).
    def for(client, registry: StandardFlags.registry, group: nil, today: Delivery.utc_today,
            env: StandardFlags.config.env_source, lookup: StandardFlags.config.client_store_lookup)
      client = Client.wrap(client)
      platform = client.platform
      app = platform && registry.client_for(platform, group: group)
      return result("unknown", platform, client.version, app&.resolve(env), lookup) if platform.nil? || client.version.nil?
      return Result.new(status: "ok", platform: platform, version: client.version, min_version: nil, recommended: nil,
                        enforce_at: nil, store_url: nil, client_app: nil) unless app

      decide(client.version, app.resolve(env), today, lookup)
    end

    def decide(version, policy, today, lookup)
      ceiling = policy.ceiling(lookup: lookup)
      minimum = capped(policy.min_version, ceiling)
      if minimum && version < minimum
        status = today >= policy.enforce_on ? "upgrade_required" : "upgrade_recommended"
        return result(status, policy.app.platform, version, policy, lookup, ceiling: ceiling, enforce_at: policy.enforce_on)
      end

      recommended = capped(policy.recommended, ceiling)
      status = recommended && version < recommended ? "upgrade_recommended" : "ok"
      result(status, policy.app.platform, version, policy, lookup, ceiling: ceiling)
    end

    def result(status, platform, version, policy, lookup, ceiling: :lookup, enforce_at: nil)
      ceiling = policy&.ceiling(lookup: lookup) if ceiling == :lookup
      Result.new(status: status, platform: platform, version: version,
                 min_version: policy && capped(policy.min_version, ceiling),
                 recommended: policy && capped(policy.recommended, ceiling),
                 enforce_at: enforce_at, store_url: policy&.app&.store_url, client_app: policy&.app)
    end

    # `version`, never above `ceiling`.
    def capped(version, ceiling)
      return version if version.nil? || ceiling.nil?

      [ version, ceiling ].min
    end
    private_class_method :decide, :result, :capped
  end
end
