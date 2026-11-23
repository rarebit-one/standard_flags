require "standard_flags"

begin
  require "open_feature/sdk"
rescue LoadError => e
  raise LoadError,
    "standard_flags/open_feature needs the openfeature-sdk gem, which standard_flags does not declare; " \
    "add `gem \"openfeature-sdk\"` to your Gemfile (#{e.message})"
end

require "standard_flags/open_feature/provider"

module StandardFlags
  # An optional OpenFeature provider over the registry, for apps that read
  # flags through the openfeature-sdk gem:
  #
  #   require "standard_flags/open_feature"
  #
  #   OpenFeature::SDK.configure do |config|
  #     config.set_provider(StandardFlags::OpenFeature::Provider.new)
  #   end
  #
  # Nothing in the gem requires this file; the app does, and brings the SDK.
  module OpenFeature
  end
end
