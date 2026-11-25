class DummyBaseController < ActionController::Base
  include StandardFlags::Controller

  protect_from_forgery with: :exception

  private

  def standard_flags_context
    StandardFlags::Context.new(actors: { account: params[:account] }.compact)
  end
end

class ReportsController < DummyBaseController
  requires_flag :new_reports, except: :index

  def index
    render plain: "index"
  end

  def show
    render plain: "show"
  end
end

class ExportsController < DummyBaseController
  requires_flag :legacy_export, error: :not_found

  def index
    render plain: "exports"
  end
end

class AssistantController < DummyBaseController
  requires_flag :ai_assistant, status: 503
  requires_flag :strict_gates, only: :index

  def index
    render plain: "assistant"
  end
end

class FeaturesController < DummyBaseController
  def index
    render json: { features: standard_flags_payload(:web) }
  end
end

class LegacyController < DummyBaseController
  requires_flag :new_reports, only: :api,
                with: ->(controller, denial) { controller.render json: { error_code: "FEATURE_OFF", flag: denial.key }, status: 422 }
  requires_flag :new_reports, only: :page, with: :render_unavailable_page
  requires_flag :new_reports, only: :plain

  def api
    render plain: "api"
  end

  def page
    render plain: "page"
  end

  def plain
    render plain: "plain"
  end

  private

  def render_unavailable_page(denial)
    render plain: "unavailable: #{denial.feature} (#{denial.status})", status: denial.status
  end
end

# Client context and FeatureDisabled.
class ClientFeaturesController < DummyBaseController
  def index
    render json: { features: standard_flags_payload(:mobile), client: standard_flags_client.to_h }
  end

  def checkout
    StandardFlags.require!(:new_checkout, for: standard_flags_request_context)
    render plain: "checkout"
  end

  def raise_disabled
    raise StandardFlags::FeatureDisabled.new(:new_checkout, status: 404)
  end

  def reader
    render plain: standard_flags_reader.on?(:new_checkout).to_s
  end

  def late
    render plain: "late"
    raise StandardFlags::FeatureDisabled, :new_checkout
  end

  private

  def standard_flags_context
    { account: "acct_1" }
  end
end

class PinnedClientController < DummyBaseController
  requires_flag :new_checkout

  def index
    render plain: "pinned"
  end

  private

  def standard_flags_context
    StandardFlags::Context.new(actors: { account: "acct_1" }, client: { platform: "ios", version: "9.0.0" })
  end
end

# An app handler for StandardError declared after the include, as an
# ApplicationController's error handling usually is.
class RescuingController < DummyBaseController
  rescue_from StandardError, with: :render_500

  def disabled
    raise StandardFlags::FeatureDisabled, :new_checkout
  end

  def boom
    raise ArgumentError, "boom"
  end

  private

  def render_500(_error)
    render plain: "app 500", status: 500
  end
end

# An app that takes FeatureDisabled over with its own handler.
class TargetedController < DummyBaseController
  rescue_from StandardFlags::FeatureDisabled, with: :render_own

  def disabled
    raise StandardFlags::FeatureDisabled, :new_checkout
  end

  private

  def render_own(error)
    render plain: "own #{error.feature}", status: 451
  end
end

# OFREP. The app authenticates (a bearer token naming the account here) and
# draws the routes; the mixin serves them.
module DummyBearerAuth
  extend ActiveSupport::Concern

  included do
    before_action :authenticate!
  end

  private

  def bearer_account
    token = request.authorization.to_s.delete_prefix("Bearer ").strip
    token unless token.empty?
  end

  def authenticate!
    head :unauthorized unless bearer_account
  end

  def standard_flags_context
    StandardFlags::Context.new(actors: { account: bearer_account })
  end
end

class OfrepFlagsController < DummyBaseController
  include DummyBearerAuth
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :mobile, csrf: :skip
end

# Keeps Rails' CSRF check: clients must send the token.
class OfrepCsrfProtectedController < DummyBaseController
  include DummyBearerAuth
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :mobile, csrf: :protect
end

# Forgery protection declared after the mixin: caught on the first request.
class OfrepLateCsrfController < ActionController::Base
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :mobile
  protect_from_forgery with: :exception
end

# An app handler for StandardError declared after the mixin.
class OfrepRescuingController < ActionController::API
  include DummyBearerAuth
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :mobile
  rescue_from StandardError, with: :render_500

  private

  def render_500(_error)
    render json: { error: "internal" }, status: 500
  end
end

class OfrepApiController < ActionController::API
  include DummyBearerAuth
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :mobile

  before_action { response.headers["Vary"] = "Accept-Encoding, accept" }
end

class OfrepPreAuthController < DummyBaseController
  include StandardFlags::OFREP::Controller

  standard_flags_ofrep audience: :pre_auth, anonymous: true, csrf: :skip

  private

  def standard_flags_context
    raise "an anonymous OFREP controller must not ask who is signed in"
  end
end

class OfrepUnconfiguredController < DummyBaseController
  include StandardFlags::OFREP::Controller
end

class BootstrapController < DummyBaseController
  def show
    render json: { profile: {}, features: standard_flags_payload(:mobile, format: :ofrep) }
  end
end

# GET /client/status: pre-auth, on the CSRF-protected base (a GET, so
# forgery protection never applies) and on one API controller, which proves
# the mixin needs nothing from ActionController::Base.
class ClientStatusController < DummyBaseController
  include StandardFlags::ClientStatus::Controller

  standard_flags_client_status

  private

  def standard_flags_context
    raise "the client status endpoint must not ask who is signed in"
  end
end

class ClientStatusApiController < ActionController::API
  include StandardFlags::ClientStatus::Controller

  before_action { response.headers["Vary"] = "Accept-Encoding" }
end

class KioskClientStatusController < DummyBaseController
  include StandardFlags::ClientStatus::Controller

  standard_flags_client_status group: :kiosk, max_age: 5
end

# requires_client_version: the 426 guard.
class UpgradeController < DummyBaseController
  requires_client_version except: :health

  def orders
    render plain: "orders"
  end

  def health
    render plain: "health"
  end
end

class UpgradeOwnController < DummyBaseController
  requires_client_version with: :render_upgrade

  def index
    render plain: "own"
  end

  private

  def render_upgrade(denial)
    render json: { error: { code: denial.error.to_s.upcase, min: denial.min_version, client: denial.key } }, status: denial.status
  end
end

class UpgradeResponderController < DummyBaseController
  requires_client_version

  def index
    render plain: "responder"
  end
end

class UpgradeKioskController < DummyBaseController
  requires_client_version group: :kiosk

  def index
    render plain: "kiosk"
  end
end

# The app's context names a client, which wins over the headers.
class UpgradeContextController < DummyBaseController
  requires_client_version

  def index
    render plain: "context"
  end

  private

  def standard_flags_context
    StandardFlags::Context.new(client: { platform: "android", version: "0.1.0" })
  end
end

class UpgradeRaiseController < DummyBaseController
  def raise_required
    status = StandardFlags::ClientStatus.for(standard_flags_client)
    raise StandardFlags::ClientUpgradeRequired.new(status) if status.upgrade_required?

    render plain: status.status
  end
end

# An app handler for StandardError declared after the include.
class UpgradeRescuingController < UpgradeRaiseController
  rescue_from StandardError, with: :render_500

  private

  def render_500(_error)
    render plain: "app 500", status: 500
  end
end

# An app that takes ClientUpgradeRequired over with its own handler.
class UpgradeTargetedController < UpgradeRaiseController
  rescue_from StandardFlags::ClientUpgradeRequired, with: :render_own

  private

  def render_own(error)
    render plain: "own #{error.min_version}", status: 400
  end
end
