module StandardFlags
  # Where the newest version of a client in its store comes from, for the
  # store ceiling (see StandardFlags::ClientApp): never enforce a minimum
  # that the store can't yet deliver.
  #
  #   client :ios_app, platform: :ios, min_version: "2.0.0", since: "2026-12-01", available: "1.9.0",
  #                    store_lookup: StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app", country: "us")
  #
  # A lookup belongs to the one client that declares it, and only ever caps
  # that client. It is any object that responds to `call(client_app)` with
  # its last known version (a String or a StandardFlags::Version), or nil,
  # and returns at once: it is asked on request threads, so it must never
  # wait on the network (AppStore refreshes in the background). When it
  # answers nil, nonsense or raises, the declared `available:` applies; a
  # pinned `_AVAILABLE` beats it. Failures emit
  # `store_lookup_failed.standard_flags` with `store`, `client` and
  # `reason`. Google Play has no public API for this,
  # so Android clients use `available:` alone.
  module Stores
    autoload :AppStore, "standard_flags/stores/app_store"

    module_function

    # The version `app`'s store lookup last reported, or nil. Never raises.
    def available(app)
      lookup = app.store_lookup
      return nil unless lookup

      Version.parse(lookup.call(app))
    rescue StandardError => e
      Reporting.once(:store_lookup, app.name, e.class.name) do
        Reporting.instrument(:store_lookup_failed, store: lookup.class.name, client: app.name, reason: e.class.name)
      end
      nil
    end
  end
end
