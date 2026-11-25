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
    # As Rails' generated config/environments/test.rb does: request specs don't
    # carry authenticity tokens; controllers still declare forgery protection.
    config.action_controller.allow_forgery_protection = false
  end
end

Dummy::Application.initialize!

Dummy::Application.routes.draw do
  get "/reports" => "reports#index"
  get "/reports/:id" => "reports#show"
  get "/exports" => "exports#index"
  get "/assistant" => "assistant#index"
  get "/features" => "features#index"
  get "/legacy/api" => "legacy#api"
  get "/legacy/page" => "legacy#page"
  get "/legacy/plain" => "legacy#plain"
  get "/client/features" => "client_features#index"
  get "/client/checkout" => "client_features#checkout"
  get "/client/raise" => "client_features#raise_disabled"
  get "/client/pinned" => "pinned_client#index"
  get "/client/reader" => "client_features#reader"
  get "/client/late" => "client_features#late"
  get "/rescuing/disabled" => "rescuing#disabled"
  get "/rescuing/boom" => "rescuing#boom"
  get "/targeted/disabled" => "targeted#disabled"
  post "/ofrep/v1/evaluate/flags" => "ofrep_flags#ofrep_evaluate_flags"
  post "/ofrep/v1/evaluate/flags/:key" => "ofrep_flags#ofrep_evaluate_flag"
  post "/api/ofrep/v1/evaluate/flags" => "ofrep_api#ofrep_evaluate_flags"
  post "/api/ofrep/v1/evaluate/flags/:key" => "ofrep_api#ofrep_evaluate_flag"
  post "/pre-auth/ofrep/v1/evaluate/flags" => "ofrep_pre_auth#ofrep_evaluate_flags"
  post "/csrf/ofrep/v1/evaluate/flags" => "ofrep_csrf_protected#ofrep_evaluate_flags"
  post "/late-csrf/ofrep/v1/evaluate/flags" => "ofrep_late_csrf#ofrep_evaluate_flags"
  post "/rescuing/ofrep/v1/evaluate/flags" => "ofrep_rescuing#ofrep_evaluate_flags"
  post "/pre-auth/ofrep/v1/evaluate/flags/:key" => "ofrep_pre_auth#ofrep_evaluate_flag"
  get "/bootstrap" => "bootstrap#show"
  get "/client/status" => "client_status#client_status"
  get "/api/client/status" => "client_status_api#client_status"
  get "/kiosk/client/status" => "kiosk_client_status#client_status"
  get "/upgrade/orders" => "upgrade#orders"
  get "/upgrade/health" => "upgrade#health"
  get "/upgrade/own" => "upgrade_own#index"
  get "/upgrade/responder" => "upgrade_responder#index"
  get "/upgrade/raise" => "upgrade_raise#raise_required"
  get "/upgrade/rescuing" => "upgrade_rescuing#raise_required"
  get "/upgrade/targeted" => "upgrade_targeted#raise_required"
  get "/upgrade/kiosk" => "upgrade_kiosk#index"
  get "/upgrade/context" => "upgrade_context#index"
end

require_relative "dummy_controllers"
