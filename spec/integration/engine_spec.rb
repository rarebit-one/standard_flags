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

  describe "rake tasks loaded through the host app" do
    let(:tasks) { %w[flags:list flags:stale flags:refs standard_flags:manifest standard_flags:typescript] }

    before do
      require "rake"
      Rake.application = Rake::Application.new
      Rails.application.load_tasks
    end

    it "registers every task" do
      expect(Rake::Task.tasks.map(&:name)).to include(*tasks)
    end

    it "defines each task once, so it runs once" do
      expect(tasks.to_h { |name| [ name, Rake::Task[name].actions.size ] }).to eq(tasks.to_h { |name| [ name, 1 ] })
    end

    it "prints flags:list once" do
      define_flags { kill_switch :ai_assistant, owner: "assistant" }
      Rake::Task["environment"].clear # the dummy app is already booted
      expect { Rake::Task["flags:list"].invoke }
        .to output(satisfy { |out| out.scan("ai_assistant").size == 1 }).to_stdout
    end
  end

  it "is not strict in a production Rails process" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    StandardFlags.config.strict = nil
    expect(StandardFlags.config).not_to be_strict
  end
end
