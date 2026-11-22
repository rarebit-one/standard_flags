require "spec_helper"

RSpec.describe "engine integration" do
  it "loads config/flags.rb on boot and on every reload" do
    expect(StandardFlags.registry).to be_empty
    Rails.application.reloader.prepare!
    expect(StandardFlags.on?(:booted_from_registry_file)).to be(true)
  end

  it "loads nothing when the registry file is missing" do
    StandardFlags.config.registry_path = "config/missing_flags.rb"
    expect(StandardFlags.load_registry!).to be_nil
    expect(StandardFlags.load_registry!(nil)).to be_nil
  end

  it "registers the rake tasks" do
    require "rake"
    Rake.application = Rake::Application.new
    Rails.application.load_tasks
    expect(Rake::Task.tasks.map(&:name)).to include("flags:list", "flags:stale", "flags:refs",
                                                     "standard_flags:manifest", "standard_flags:typescript")
  end

  it "is not strict in a production Rails process" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    StandardFlags.config.strict = nil
    expect(StandardFlags.config).not_to be_strict
  end
end
