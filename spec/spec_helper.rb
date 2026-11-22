require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  skip "/spec/"
end

ENV["RAILS_ENV"] = "test"

require "rails"
require "action_controller/railtie"
require "active_job/railtie"
require "standard_flags"
require_relative "support/dummy_app"
require "standard_flags/rspec"

Dir[File.join(__dir__, "support/helpers/*.rb")].each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |m|
    m.verify_partial_doubles = true
  end

  config.order = :random
  Kernel.srand config.seed

  config.include FlagSpecHelpers

  # Runs before standard_flags/rspec's own reset, which then clears overrides
  # and report memory on top of the fresh registry and config.
  # A `registry:` metadata proc is defined here, before standard_flags/rspec
  # applies `flags:` metadata, the way a host app's registry is loaded at boot.
  config.prepend_before do |example|
    StandardFlags.reset!
    StandardFlags::Testing.activate!
    StandardFlags.config.env_source = {}
    StandardFlags.define(&example.metadata[:registry]) if example.metadata[:registry]
  end
end
