require "logger"

# A minimal host app booted once for the whole suite, so the engine's
# initializers (executor hook, registry loading, subscribers) run for real.
module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("dummy", __dir__)
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "0" * 64
    config.hosts.clear
    config.active_support.deprecation = :stderr
    config.active_job.queue_adapter = :test
  end
end

Dummy::Application.initialize!

Dummy::Application.routes.draw do
  get "/reports" => "reports#index"
  get "/reports/:id" => "reports#show"
  get "/exports" => "exports#index"
  get "/assistant" => "assistant#index"
  get "/features" => "features#index"
end

require_relative "dummy_controllers"
