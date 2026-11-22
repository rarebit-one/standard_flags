module StandardFlags
  # Library-only engine: no routes, and no models in app/ (the runtime-rule
  # models load only when runtime rules are on). It wires these into the
  # host:
  #
  # * an executor hook that opens a fresh memo per unit of work (requests,
  #   jobs, mailers, console reloads), instead of Rack middleware;
  # * config/flags.rb, loaded on boot and on every code reload;
  # * the Logger / Sentry / Metrics subscribers, once initializers have run;
  # * the runtime-rule store, after boot, when runtime rules are on.
  #
  # Rake tasks need no `rake_tasks` block: Rails::Engine already loads
  # lib/tasks/**/*.rake, and loading the file again would give every task a
  # second action.
  class Engine < ::Rails::Engine
    isolate_namespace StandardFlags

    initializer "standard_flags.executor" do |app|
      app.executor.register_hook(StandardFlags::Memo::Hook)
    end

    initializer "standard_flags.subscribers", after: :load_config_initializers do
      StandardFlags.subscribers.setup!
    end

    config.to_prepare do
      StandardFlags.load_registry!
    end

    # Loads the ActiveRecord store (and ActiveRecord) at boot, but only when
    # the host has turned runtime rules on.
    config.after_initialize do
      StandardFlags::Runtime.boot!
    end
  end
end
