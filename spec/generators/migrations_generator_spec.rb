require "spec_helper"
require "fileutils"
require "stringio"
require "rails/generators"
require "generators/standard_flags/migrations/migrations_generator"
require "generators/standard_flags/install/install_generator"

RSpec.describe StandardFlags::Generators::MigrationsGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../tmp/migrations_dest", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
  end

  after { FileUtils.rm_rf(destination_root) }

  def quietly
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def migrations
    Dir[File.join(destination_root, "db/migrate/*_create_standard_flags_tables.rb")]
  end

  def with_primary_key_type(type)
    generators = Rails.application.config.generators
    previous = generators.options[:active_record].dup
    generators.options[:active_record][:primary_key_type] = type
    yield
  ensure
    generators.options[:active_record] = previous
  end

  it "writes one migration creating the four tables with bigint keys by default" do
    quietly { described_class.start([], destination_root: destination_root) }
    expect(migrations.size).to eq(1)
    content = File.read(migrations.first)
    expect(content).to include("class CreateStandardFlagsTables < ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]")
    expect(content.scan(/create_table :(\w+)/).flatten)
      .to eq(%w[standard_flags_rules standard_flags_cohorts standard_flags_memberships standard_flags_state])
    expect(content).not_to include("id: :uuid")
    expect(content).to include("type: :bigint")
  end

  it "uses UUID keys when the app generates them" do
    with_primary_key_type(:uuid) { quietly { described_class.start([], destination_root: destination_root) } }
    content = File.read(migrations.first)
    expect(content.scan("id: :uuid").size).to eq(4)
    expect(content.scan("type: :uuid").size).to eq(2)
  end

  it "skips when the migration already exists" do
    quietly { described_class.start([], destination_root: destination_root) }
    expect(quietly { described_class.start([], destination_root: destination_root) }).to include("already present, skipping")
    expect(migrations.size).to eq(1)
  end

  describe "standard_flags:install --runtime" do
    it "also writes the migration" do
      output = quietly { StandardFlags::Generators::InstallGenerator.start([ "--runtime" ], destination_root: destination_root) }
      expect(migrations.size).to eq(1)
      expect(output).to include("set config.runtime_rules = true")
    end

    it "writes no migration without it" do
      quietly { StandardFlags::Generators::InstallGenerator.start([], destination_root: destination_root) }
      expect(migrations).to be_empty
    end
  end
end
