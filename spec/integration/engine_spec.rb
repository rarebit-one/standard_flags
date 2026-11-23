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
    let(:tasks) do
      %w[flags:list flags:stale flags:refs flags:show flags:set flags:ramp flags:start flags:pause flags:stop
         flags:members:add flags:members:remove flags:purge standard_flags:manifest standard_flags:typescript]
    end

    before { Rake.application = RakeTasks.application }

    it "registers every task" do
      expect(Rake::Task.tasks.map(&:name)).to include(*tasks)
    end

    it "defines each task once, so it runs once" do
      expect(tasks.to_h { |name| [ name, Rake::Task[name].actions.size ] }).to eq(tasks.to_h { |name| [ name, 1 ] })
    end

    it "prints flags:list once" do
      define_flags { kill_switch :ai_assistant, owner: "assistant" }
      expect { RakeTasks.invoke("flags:list") }
        .to output(satisfy { |out| out.scan("ai_assistant").size == 1 }).to_stdout
    end
  end

  it "is not strict in a production Rails process" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    StandardFlags.config.strict = nil
    expect(StandardFlags.config).not_to be_strict
  end
end
