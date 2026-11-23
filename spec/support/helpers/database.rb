require "stringio"


# Specs tagged :db run against Postgres and only when DATABASE_URL is set,
# so the default matrix never needs a database (or loads ActiveRecord).
module DatabaseHelpers
  TABLES = %w[standard_flags_memberships standard_flags_cohorts standard_flags_rules standard_flags_state].freeze

  module_function

  def available?
    ENV["DATABASE_URL"].to_s.start_with?("postgres")
  end

  # Connects, then recreates the runtime tables from the generated migration
  # with StrongMigrations loaded, so every run also proves the migration is
  # one StrongMigrations accepts.
  def prepare!
    return if @prepared

    require "active_record"
    require "strong_migrations"
    require "rails/generators"
    require "generators/standard_flags/migrations/migrations_generator"
    ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
    ActiveRecord::Migration.verbose = false
    connection = ActiveRecord::Base.connection
    TABLES.each { |table| connection.drop_table(table, if_exists: true) }
    run_generated_migration(:up)
    create_audit_logs(connection)
    @prepared = true
  end

  # standard_audit's audit_logs table (the columns of its install
  # migration), for the specs that read the write path's history back
  # through its query API. Created only when missing, so a database that
  # already has the real table keeps it.
  def create_audit_logs(connection)
    return if connection.table_exists?(:audit_logs)

    connection.create_table :audit_logs, id: :uuid do |t|
      t.string :actor_gid
      t.string :actor_type
      t.string :target_gid
      t.string :target_type
      t.string :scope_gid
      t.string :scope_type
      t.string :event_type, null: false
      t.string :request_id
      t.string :ip_address
      t.text :user_agent
      t.string :session_id
      t.jsonb :metadata, default: {}
      t.datetime :occurred_at, null: false
      t.string :checksum, limit: 64
      t.string :previous_checksum, limit: 64
      t.datetime :anonymized_at
      t.timestamps
      t.index [ :occurred_at, :created_at ]
      t.index :event_type
    end
  end

  def run_generated_migration(direction, destination: File.expand_path("../../../tmp/db_migration", __dir__))
    FileUtils.rm_rf(destination)
    capture_stdout { StandardFlags::Generators::MigrationsGenerator.start([], destination_root: destination) }
    load Dir[File.join(destination, "db/migrate/*_create_standard_flags_tables.rb")].first
    CreateStandardFlagsTables.migrate(direction)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def clean!
    connection = ActiveRecord::Base.connection
    connection.execute("TRUNCATE #{(TABLES + %w[audit_logs]).join(', ')} RESTART IDENTITY CASCADE")
    connection.execute("INSERT INTO standard_flags_state (revision) VALUES (0)")
  end

  # SQL statements run by the block, without schema and transaction noise.
  def queries
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])

      statements << payload[:sql]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

# The Postgres CI job sets REQUIRE_DATABASE so a broken DATABASE_URL fails
# the run instead of silently skipping every :db spec.
if ENV["REQUIRE_DATABASE"] == "1" && !DatabaseHelpers.available?
  raise "REQUIRE_DATABASE=1 but DATABASE_URL is not a postgres:// URL"
end

RSpec.configure do |config|
  config.filter_run_excluding :db unless DatabaseHelpers.available?

  config.before(:context, :db) { DatabaseHelpers.prepare! }
  config.before(:each, :db) { DatabaseHelpers.clean! }
end
