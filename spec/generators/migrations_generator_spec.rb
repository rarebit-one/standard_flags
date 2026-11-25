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
    # The Postgres run has the tables; these examples are about files.
    allow(described_class).to receive(:table_present?).and_return(false)
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

  describe "the compat stats migration" do
    def compat_migrations
      Dir[File.join(destination_root, "db/migrate/*_create_standard_flags_compat_stats.rb")]
    end

    it "is written alongside, as a separate, later migration" do
      quietly { described_class.start([], destination_root: destination_root) }
      expect(compat_migrations.size).to eq(1)
      expect(File.basename(compat_migrations.first) > File.basename(migrations.first)).to be(true)
    end

    it "creates the one table, with a unique index on key and platform" do
      quietly { described_class.start([], destination_root: destination_root) }
      content = File.read(compat_migrations.first)
      expect(content).to include("class CreateStandardFlagsCompatStats < ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]")
      expect(content.scan(/create_table :(\w+)/).flatten).to eq(%w[standard_flags_compat_stats])
      expect(content).to include("t.index %i[key platform], unique: true")
      expect(content).to include("t.datetime :first_seen_at, null: false")
      expect(content).not_to include("id: :uuid")
    end

    it "is the only one added for an app that already ran the first (the additive upgrade path)" do
      FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
      File.write(File.join(destination_root, "db/migrate/20260101000000_create_standard_flags_tables.rb"), "# existing\n")
      output = quietly { described_class.start([], destination_root: destination_root) }
      expect(output).to include("create_standard_flags_tables already present, skipping")
      expect(migrations.size).to eq(1)
      expect(File.read(migrations.first)).to eq("# existing\n")
      expect(compat_migrations.size).to eq(1)
    end

    it "uses UUID keys when the app generates them" do
      with_primary_key_type(:uuid) { quietly { described_class.start([], destination_root: destination_root) } }
      expect(File.read(compat_migrations.first)).to include("create_table :standard_flags_compat_stats, id: :uuid do |t|")
    end

    it "skips a migration whose table already exists, as for an app that squashed the first one" do
      allow(described_class).to receive(:table_present?) { |table| table == "standard_flags_rules" }
      output = quietly { described_class.start([], destination_root: destination_root) }
      expect(output).to include("standard_flags_rules already exists in the database, skipping create_standard_flags_tables")
      expect([ migrations.size, compat_migrations.size ]).to eq([ 0, 1 ])
    end

    it "writes nothing on a rerun once both tables exist, unless told not to check" do
      allow(described_class).to receive(:table_present?).and_return(true)
      quietly { described_class.start([], destination_root: destination_root) }
      expect([ migrations.size, compat_migrations.size ]).to eq([ 0, 0 ])
      quietly { described_class.start([ "--no-check-tables" ], destination_root: destination_root) }
      expect([ migrations.size, compat_migrations.size ]).to eq([ 1, 1 ])
    end

    it "asks the database, and answers false without one" do
      expect(described_class).to receive(:table_present?).and_call_original
      expect(described_class.table_present?("standard_flags_nope")).to be(false)
    end
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
