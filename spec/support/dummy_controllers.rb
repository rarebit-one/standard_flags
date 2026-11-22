class DummyBaseController < ActionController::Base
  include StandardFlags::Controller

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
