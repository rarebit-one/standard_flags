require "spec_helper"

RSpec.describe StandardFlags::Job do
  include ActiveJob::TestHelper

  before do
    define_flags do
      kill_switch :ai_assistant, owner: "assistant"
      flag :new_importer, owner: "data", remove_by: "2027-01-01", final: true
    end
  end

  let(:performed) { [] }

  def job_class(**options, &extra)
    log = performed
    Class.new(ActiveJob::Base) do
      include StandardFlags::Job

      define_singleton_method(:name) { "ProbeJob" }
      requires_flag(options.delete(:key) || :ai_assistant, **options)
      class_eval(&extra) if extra
      define_method(:perform) { |*args| log << args }
    end
  end

  it "runs the job when the flag is on" do
    job_class.perform_now(1)
    expect(performed).to eq([ [ 1 ] ])
  end

  it "discards the job when the flag is off" do
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    job_class.perform_now(1)
    expect(performed).to be_empty
  end

  it "raises StandardFlags::Disabled with retry: true" do
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    expect { job_class(retry: true).perform_now }.to raise_error(StandardFlags::Disabled, "flag :ai_assistant is disabled")
  end

  it "lets retry_on reschedule" do
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    klass = job_class(retry: true) { retry_on StandardFlags::Disabled, wait: 60, attempts: 3 }
    klass.perform_now
    expect([ performed, enqueued_jobs.size ]).to eq([ [], 1 ])
  end

  it "evaluates for: in the job instance" do
    seen = nil
    klass = job_class(key: :new_importer, for: -> { arguments.first })
    allow(StandardFlags).to receive(:reader).and_wrap_original do |original, **kwargs|
      seen = kwargs[:for]
      original.call(**kwargs)
    end
    with_flag(:new_importer, true) { klass.perform_now("acct_9") }
    expect([ seen, performed ]).to eq([ "acct_9", [ [ "acct_9" ] ] ])
  end

  it "rejects unknown options" do
    expect { job_class(retries: 3) }.to raise_error(ArgumentError, /:retries/)
  end

  it "exposes the key on Disabled" do
    expect(StandardFlags::Disabled.new("ai_assistant").key).to eq(:ai_assistant)
  end
end
