require "spec_helper"
require "open3"

# standard_health 0.9 runs its load hooks when it is required. If it loads
# before standard_flags, ActiveSupport runs the flags hook the moment it is
# registered, so the hook must be registered only after everything it calls
# exists. A fresh process reproduces the boot order.
RSpec.describe "requiring standard_flags after standard_health has run its hooks" do # rubocop:disable RSpec/DescribeClass
  let(:script) { <<~RUBY }
    require "active_support"
    contributed = []
    facade = Object.new
    facade.define_singleton_method(:contribute_check) { |name, *_args, **_opts| contributed << name }
    facade.define_singleton_method(:contribute_env_vars) { |*_args, **_opts, &_blk| nil }
    ActiveSupport.run_load_hooks(:standard_health, facade)
    require "standard_flags"
    print contributed.inspect
  RUBY

  it "boots and contributes the check" do
    gemfile = File.expand_path("../../Gemfile", __dir__)
    out, err, status = Open3.capture3({ "BUNDLE_GEMFILE" => gemfile }, RbConfig.ruby,
                                      "-I", File.expand_path("../../lib", __dir__), "-e", script)
    expect(status).to be_success, err
    expect(out).to eq("[:standard_flags]")
  end
end
