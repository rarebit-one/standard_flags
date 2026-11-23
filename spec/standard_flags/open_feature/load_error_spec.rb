require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# The SDK is never a dependency, so requiring the provider without it must
# say what to add. Run in a child process whose load path puts a stand-in
# for "open_feature/sdk" first, which fails the way a missing gem does.
RSpec.describe StandardFlags do
  it "raises a LoadError naming openfeature-sdk when standard_flags/open_feature is required without it" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "open_feature"))
      File.write(File.join(dir, "open_feature", "sdk.rb"), %(raise LoadError, "cannot load such file -- open_feature/sdk"\n))
      script = <<~RUBY
        begin
          require "standard_flags/open_feature"
          puts "loaded"
        rescue LoadError => e
          puts e.message
        end
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", dir, "-I", lib, "-e", script)

      expect(status).to be_success, err
      expect(out.strip).to eq(
        "standard_flags/open_feature needs the openfeature-sdk gem, which standard_flags does not declare; " \
        "add `gem \"openfeature-sdk\"` to your Gemfile (cannot load such file -- open_feature/sdk)"
      )
    end
  end
end
