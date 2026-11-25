require "date"
require "uri"

module StandardFlags
  # One app build channel the server knows about, declared in
  # config/flags.rb:
  #
  #   client :android_app, platform: :android, min_version: "0.4.0", since: "2026-12-01",
  #          recommended: "0.5.0", available: "0.5.0", store_url: "https://example.com/app", grace: 7.days
  #
  # * `min_version:` is the oldest build allowed to keep working. `since:`
  #   (required with it) is the date it was raised; it is enforced from
  #   `since + grace` (default 7 days, whole days, UTC dates).
  # * `available:` is the newest version known to be in that store. The
  #   enforced minimum (and the recommended version) is never above it, so a
  #   minimum raised before a release has passed review locks nobody out.
  #   `store_lookup:` can supply it live for this client (the App Store; see
  #   StandardFlags::Stores), falling back to `available:`.
  # * `recommended:` nudges builds below it without blocking them.
  # * `group:` lets two apps share a platform: clients are unique per
  #   (group, platform), and the status endpoint and the 426 guard pick a
  #   group (nil, the default group, unless told otherwise).
  #
  # Raising `min_version:` means moving `since:` to the day of the raise;
  # otherwise the old date makes the new minimum enforced at once.
  #
  # ENV break-glass pins beat the code and any store lookup, as a flag's
  # pin does: STANDARD_FLAGS_CLIENT_<NAME>_MIN_VERSION, _SINCE,
  # _RECOMMENDED and _AVAILABLE. A pin that doesn't parse is ignored (and
  # reported, by name only). So is a pinned minimum that raises the code's
  # one (or sets one where the code has none) without a pinned `_SINCE`: a
  # break-glass raise can't skip the grace window. Lowering the minimum
  # needs no `_SINCE`; a pin lowers it only when every version that meets
  # the code's minimum also meets the pin (so `1.0.0-rc.1` against `1.0.0`
  # is a raise: it stops `1.0.0-beta.1`, which `1.0.0` lets through).
  ClientApp = Data.define(:name, :platform, :group, :min_version, :since, :grace_days, :recommended, :available,
                          :store_url, :store_lookup)

  class ClientApp
    # Pin suffix => attribute.
    PINS = { "MIN_VERSION" => :min_version, "SINCE" => :since, "RECOMMENDED" => :recommended,
             "AVAILABLE" => :available }.freeze
    DEFAULT_GRACE_DAYS = 7
    DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

    # A ClientApp with its ENV pins applied: what the status endpoint and the
    # 426 guard work from. `pinned` and `rejected` name the ENV variables
    # that applied and that were ignored.
    Policy = Data.define(:app, :min_version, :since, :recommended, :available, :pinned, :rejected) do
      # The first day the minimum is enforced: since + grace.
      def enforce_on
        since && since + app.grace_days
      end

      # The newest version known to be in the store: a pinned `_AVAILABLE`,
      # else the client's store lookup's last answer, else `available:`.
      # Never waits on a store.
      def ceiling
        return available if available_pinned?

        Stores.available(app) || available
      end

      def available_pinned?
        pinned.include?(app.env_var(:available))
      end
    end

    class << self
      # Builds a ClientApp from a `client` declaration, raising
      # DefinitionError for anything that can't work.
      def declare(name, platform:, min_version: nil, since: nil, recommended: nil, available: nil, store_url: nil,
                  grace: nil, group: nil, store_lookup: nil)
        name = name.to_s
        fail = ->(message) { raise DefinitionError, "client :#{name} #{message}" }
        fail.call("name must match #{Definition::KEY_FORMAT.inspect}") unless name.match?(Definition::KEY_FORMAT)
        group = group&.to_s
        fail.call("group: must match #{Definition::KEY_FORMAT.inspect}") if group && !group.match?(Definition::KEY_FORMAT)

        versions = { min_version: min_version, recommended: recommended, available: available }
                   .to_h { |attribute, value| [ attribute, declared_version(attribute, value, fail) ] }
        since_date = since.nil? ? nil : date(since)
        fail.call("since: #{since.inspect} is not a YYYY-MM-DD date") if !since.nil? && since_date.nil?
        fail.call("min_version: needs since: (the date the minimum was raised)") if versions[:min_version] && since_date.nil?
        fail.call("since: needs min_version:") if since_date && versions[:min_version].nil?
        if versions[:recommended] && versions[:min_version] && versions[:recommended] < versions[:min_version]
          fail.call("recommended: #{versions[:recommended]} is below min_version: #{versions[:min_version]}")
        end

        unless store_lookup.nil? || store_lookup.respond_to?(:call)
          fail.call("store_lookup: must respond to call(client_app) (StandardFlags::Stores::AppStore, say)")
        end

        new(name: name.to_sym, platform: declared_platform(platform, fail), group: group&.to_sym, **versions,
            since: since_date, grace_days: grace_days(grace, fail), store_url: declared_url(store_url, fail),
            store_lookup: store_lookup)
      end

      # A YYYY-MM-DD String, a Date, or a Time or DateTime (as its UTC date)
      # as a Date, or nil.
      def date(value)
        return value.to_time.utc.to_date if value.is_a?(DateTime) || value.is_a?(Time)
        return value if value.is_a?(Date)

        text = Version.clean(value)
        text&.match?(DATE_FORMAT) ? Date.iso8601(text) : nil
      rescue Date::Error
        nil
      end

      private

      def declared_platform(platform, fail)
        platforms = StandardFlags.config.client_platforms.map { |known| known.to_s.downcase } - [ Client::UNKNOWN_PLATFORM ]
        name = platform.to_s.downcase
        fail.call("platform: #{platform.inspect} is not one of config.client_platforms #{platforms.inspect}") unless platforms.include?(name)
        name.freeze
      end

      def declared_version(attribute, value, fail)
        return nil if value.nil?

        parsed = value.is_a?(String) ? Version.parse(value) : nil
        fail.call("#{attribute}: #{value.inspect} is not a version (\"0.4.0\")") if parsed.nil?
        parsed
      end

      # `grace:` as whole days: an Integer number of days or a Duration of
      # whole days (7.days).
      def grace_days(grace, fail)
        return DEFAULT_GRACE_DAYS if grace.nil?

        # A Duration answers is_a?(Integer) for its value, so it goes first.
        seconds =
          if grace.is_a?(ActiveSupport::Duration) then grace.to_i
          elsif grace.is_a?(Integer) then grace * 86_400
          end
        unless seconds.is_a?(Integer) && seconds >= 0 && (seconds % 86_400).zero?
          fail.call("grace: must be a whole number of days (7 or 7.days), not #{grace.inspect}")
        end
        seconds / 86_400
      end

      def declared_url(url, fail)
        return nil if url.nil?

        uri = url.is_a?(String) ? URI.parse(url) : nil
        fail.call("store_url: must be an http(s) URL") unless uri && %w[http https].include?(uri.scheme) && uri.host
        url.dup.freeze
      rescue URI::InvalidURIError
        fail.call("store_url: must be an http(s) URL")
      end
    end

    # The ENV pin for `attribute` (:min_version, :since, :recommended or
    # :available).
    def env_var(attribute)
      suffix = PINS.key(attribute.to_sym) or raise ArgumentError, "no pin for #{attribute.inspect}"
      "STANDARD_FLAGS_CLIENT_#{name.to_s.upcase}_#{suffix}"
    end

    def env_vars
      PINS.values.map { |attribute| env_var(attribute) }
    end

    # This client with its ENV pins applied (a Policy). Reads `env`
    # (anything that answers `[]`); never raises.
    def resolve(env = StandardFlags.config.env_source)
      values = { min_version: min_version, since: since, recommended: recommended, available: available }
      pinned = []
      rejected = []
      PINS.each_value do |attribute|
        var = env_var(attribute)
        raw = read(env, var)
        next if raw.nil? || raw.strip.empty?

        text = Version.clean(raw)
        value = text && (attribute == :since ? ClientApp.date(text) : Version.parse(text))
        if value.nil?
          rejected << var
        else
          pinned << var
          values[attribute] = value
        end
      end
      refuse_unscheduled_minimum(values, pinned, rejected)
      Policy.new(app: self, **values, pinned: pinned.freeze, rejected: rejected.freeze)
    end

    def store_lookup?
      !store_lookup.nil?
    end

    def inspect
      "#<StandardFlags::ClientApp :#{name} #{platform}#{" (#{group})" if group}>"
    end

    private

    # A pinned minimum that raises the code's (or sets one where it has
    # none) needs a pinned since, so a break-glass raise gets its own grace
    # window instead of reusing the code's old date.
    def refuse_unscheduled_minimum(values, pinned, rejected)
      var = env_var(:min_version)
      return unless pinned.include?(var) && !pinned.include?(env_var(:since))
      return if min_version && relaxes?(values[:min_version], min_version)

      pinned.delete(var)
      rejected << var
      values[:min_version] = min_version
    end

    # Whether every version that meets `code` (by ClientStatus.meets?) also
    # meets `pin`. Meeting is monotonic, so it is enough to check the
    # lowest version that meets `code`: `code` itself when it is a
    # prerelease, else the lowest prerelease of its release (`1.0.0-0`).
    def relaxes?(pin, code)
      lowest = code.prerelease? ? code : Version.parse("#{code.major}.#{code.minor}.#{code.patch}-0")
      ClientStatus.meets?(lowest, pin)
    end

    def read(env, var)
      value = env[var]
      value&.to_s
    rescue StandardError
      nil
    end
  end
end
