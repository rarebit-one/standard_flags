require "spec_helper"

RSpec.describe StandardFlags::Job do
  include ActiveJob::TestHelper

  before do
    # RSpec doesn't run ActiveJob::TestHelper's Minitest setup, so clear the
    # test adapter's queue by hand.
    clear_enqueued_jobs
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

  describe "error:" do
    let(:upstream_error) { stub_const("UpstreamUnavailable", Class.new(StandardError)) }

    before { set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off") }

    it "raises the given class with the default message" do
      expect { job_class(error: upstream_error).perform_now }.to raise_error(upstream_error, "flag :ai_assistant is disabled")
      expect(performed).to be_empty
    end

    it "raises what a proc returns, evaluated in the job instance with the key" do
      error = upstream_error
      klass = job_class(error: ->(key) { error.new("#{key} off for #{arguments.first}") })
      expect { klass.perform_now("acct_9") }.to raise_error(upstream_error, "ai_assistant off for acct_9")
    end

    it "accepts a proc that takes no arguments and returns a class" do
      error = upstream_error
      expect { job_class(error: -> { error }).perform_now }.to raise_error(upstream_error, "flag :ai_assistant is disabled")
    end

    it "lets the job's existing retry_on reschedule" do
      error = upstream_error
      klass = job_class(error: error) { retry_on error, wait: 60, attempts: 3 }
      klass.perform_now
      expect([ performed, enqueued_jobs.size ]).to eq([ [], 1 ])
    end

    it "ignores retry: true, since error: always raises" do
      expect { job_class(error: upstream_error, retry: true).perform_now }.to raise_error(upstream_error)
    end

    it "runs the job when the flag is on" do
      set_env({})
      job_class(error: upstream_error).perform_now(1)
      expect(performed).to eq([ [ 1 ] ])
    end

    it "rejects retry: false, which would contradict it" do
      expect { job_class(error: upstream_error, retry: false) }.to raise_error(ArgumentError, /drop retry: false/)
    end

    it "rejects anything that is not an exception class or a proc" do
      expect { job_class(error: String) }.to raise_error(ArgumentError, /exception class or a proc/)
      expect { job_class(error: "UpstreamUnavailable") }.to raise_error(ArgumentError, /exception class or a proc/)
    end
  end

  it "rejects unknown options" do
    expect { job_class(retries: 3) }.to raise_error(ArgumentError, /:retries/)
  end

  it "exposes the key on Disabled" do
    expect(StandardFlags::Disabled.new("ai_assistant").key).to eq(:ai_assistant)
  end
end
