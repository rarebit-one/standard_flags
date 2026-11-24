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
class ClientFeaturesController < ActionController::Base
  include StandardFlags::Controller

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

  private

  def standard_flags_context
    { account: "acct_1" }
  end
end

class PinnedClientController < ActionController::Base
  include StandardFlags::Controller

  requires_flag :new_checkout

  def index
    render plain: "pinned"
  end

  private

  def standard_flags_context
    StandardFlags::Context.new(actors: { account: "acct_1" }, client: { platform: "ios", version: "9.0.0" })
  end
end
