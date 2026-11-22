require "spec_helper"

RSpec.describe "config.error_reporter" do
  it "replaces Rails.error for every report" do
    reports = []
    StandardFlags.config.error_reporter = ->(error, context) { reports << [ error.class, context ] }
    errors = collect_errors { StandardFlags::Reporting.report(StandardFlags::PinRejected.new("x"), flag: "a") }
    expect(reports).to eq([ [ StandardFlags::PinRejected, { flag: "a" } ] ])
    expect(errors.reports).to be_empty
  end

  it "falls back to Rails.error when the custom reporter raises" do
    StandardFlags.config.error_reporter = ->(_error, _context) { raise "tracker down" }
    errors = nil
    expect do
      errors = collect_errors { StandardFlags::Reporting.report(StandardFlags::PinRejected.new("x"), flag: "a") }
    end.to output(/config.error_reporter failed \(RuntimeError\); reporting through Rails.error/).to_stderr
    expect(errors.errors_of(StandardFlags::PinRejected).size).to eq(1)
  end

  it "carries runtime store failures" do
    reports = []
    StandardFlags.config.error_reporter = ->(error, context) { reports << [ error.message, context ] }
    store = Class.new(StandardFlags::Runtime::MemoryStore) do
      def revision = raise(StandardFlags::Runtime::StoreError.new("revision check failed", cause_class: "PG::ConnectionBad"))
    end.new
    StandardFlags::Runtime::Cache.new(store).snapshot
    expect(reports).to eq([ [ "revision check failed", { runtime: "refresh" } ] ])
  end

  it "must be callable" do
    expect { StandardFlags.config.error_reporter = "sentry" }.to raise_error(ArgumentError, /call\(error, context\)/)
  end
end
