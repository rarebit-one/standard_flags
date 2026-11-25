module StandardFlags
  # Where the newest version of a client in its store comes from, for the
  # store ceiling (see StandardFlags::ClientApp): never enforce a minimum
  # that the store can't yet deliver.
  #
  #   config.client_store_lookup = StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app", country: "us")
  #   # or, per client:
  #   config.client_store_lookup = { ios_app: StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app") }
  #
  # A lookup is any object that responds to `call(client_app)` and returns
  # a version String (or a StandardFlags::Version), or nil when it doesn't
  # know. A single lookup is asked about iOS clients only; a Hash names the
  # client each lookup answers for. When it fails, returns nil or raises,
  # the declared `available:` applies. Google Play has no public API for
  # this, so Android clients use `available:` alone.
  module Stores
    autoload :AppStore, "standard_flags/stores/app_store"

    module_function

    # The version `lookup` reports for `app`, or nil. Never raises.
    def available(app, lookup)
      adapter =
        case lookup
        when nil then nil
        when Hash then lookup[app.name] || lookup[app.name.to_s]
        else lookup if app.platform == "ios"
        end
      return nil unless adapter

      Version.parse(adapter.call(app))
    rescue StandardError => e
      Reporting.once(:store_lookup, app.name, e.class.name) do
        Reporting.instrument(:store_lookup_failed, client: app.name, error_class: e.class.name)
      end
      nil
    end
  end
end
