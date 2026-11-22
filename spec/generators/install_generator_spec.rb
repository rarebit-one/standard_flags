require "spec_helper"
require "fileutils"
require "stringio"
require "rails/generators"
require "generators/standard_flags/install/install_generator"

RSpec.describe StandardFlags::Generators::InstallGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../tmp/generator_dest", __dir__) }
  let(:initializer_path) { File.join(destination_root, "config/initializers/standard_flags.rb") }
  let(:registry_path) { File.join(destination_root, "config/flags.rb") }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
  end

  after do
    FileUtils.rm_rf(destination_root)
  end

  def run_generator(args = [])
    captured = StringIO.new
    original_stdout = $stdout
    $stdout = captured
    described_class.start(args, destination_root: destination_root)
    captured.string
  ensure
    $stdout = original_stdout
  end

  it "writes a commented initializer" do
    run_generator
    content = File.read(initializer_path)
    expect(content).to include("StandardFlags.configure do |config|", "config.evaluate_sample_rate", "StandardFlags::HealthCheck")
    expect(content.lines.reject { |line| line.strip.empty? || line.start_with?("#") }).to be_empty
  end

  it "writes a registry with one commented example per kind" do
    run_generator
    content = File.read(registry_path)
    expect(content).to include("StandardFlags.define do", "# flag :new_checkout", "# kill_switch :ai_assistant",
                               "# mode :strict_gates", "# experiment :home_hero", "# compat :legacy_form_auth",
                               "# tombstone :manual_entry")
  end

  it "writes a registry that loads as-is and with every example uncommented" do
    run_generator
    load registry_path
    expect(StandardFlags.registry).to be_empty

    code = /^  # (?=(?:env_resolver|unit|flag|kill_switch|mode|experiment|compat|tombstone) )/
    continuation = /^  #(?=\s{2,}\S)/
    File.write(registry_path, File.read(registry_path).gsub(code, "  ").gsub(continuation, "  "))
    load registry_path
    expect(StandardFlags.registry.keys).to match_array(%i[new_checkout ai_assistant strict_gates home_hero legacy_form_auth demo_data])
  end

  it "skips existing files and overwrites with --force" do
    run_generator
    File.write(registry_path, "# mine\n")

    expect(run_generator).to include("already present, skipping")
    expect(File.read(registry_path)).to eq("# mine\n")

    run_generator([ "--force" ])
    expect(File.read(registry_path)).to include("StandardFlags.define do")
  end
end
