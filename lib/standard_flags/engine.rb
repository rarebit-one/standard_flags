module StandardFlags
  # Library-only engine: no routes, no models. It wires three things into the
  # host:
  #
  # * an executor hook that opens a fresh memo per unit of work (requests,
  #   jobs, mailers, console reloads), instead of Rack middleware;
  # * config/flags.rb, loaded on boot and on every code reload;
  # * the Logger / Sentry / Metrics subscribers, once initializers have run.
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

    rake_tasks do
      load File.expand_path("../tasks/standard_flags.rake", __dir__)
    end
  end
end
