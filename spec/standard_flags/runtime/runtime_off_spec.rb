require "spec_helper"
require "open3"
require "rbconfig"

# With runtime rules off (the default) a host must behave exactly as on
# 0.1.0: in particular nothing in the gem may load ActiveRecord. This runs in
# a fresh process because other specs in this suite load ActiveRecord.
RSpec.describe "runtime rules off" do
  def script = <<~RUBY
    require "bundler/setup"
    require "rails"
    require "action_controller/railtie"
    require "standard_flags"
    StandardFlags.define do
      unit :account, from: ->(ctx) { ctx.account }
      flag :new_checkout, owner: "payments", remove_by: "2099-01-01", final: true, unit: :account,
           bucketing: { version: 1, salt: "old" }
      kill_switch :ai_assistant, owner: "assistant"
    end
    StandardFlags.evaluate(:new_checkout, for: { account: Struct.new(:id).new(1) })
    StandardFlags.snapshot
    StandardFlags.preload(:account, [ 1, 2 ])
    StandardFlags::Diagnostics.report
    StandardFlags::Tooling::List.new.render
    StandardFlags::Runtime.boot!
    loaded = $LOADED_FEATURES.grep(%r{/active_record(/|\\.rb)}).size
    print [ defined?(::ActiveRecord).inspect, loaded, defined?(StandardFlags::Runtime::ActiveRecordStore).inspect ].join(" ")
  RUBY

  it "never loads ActiveRecord" do
    gemfile = File.expand_path("../../../Gemfile", __dir__)
    out, err, status = Open3.capture3({ "BUNDLE_GEMFILE" => gemfile }, RbConfig.ruby,
                                      "-I", File.expand_path("../../../lib", __dir__), "-e", script)
    expect(status).to be_success, err
    expect(out).to eq("nil 0 nil")
  end

  it "is the default" do
    expect(StandardFlags.config).to have_attributes(runtime_rules: false, refresh_interval: 5, runtime_store: nil,
                                                    segment_resolver: nil, error_reporter: nil)
    expect(StandardFlags::Runtime).not_to be_enabled
  end
end
