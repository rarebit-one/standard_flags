require "rails/generators"
require "rails/generators/active_record"

module StandardFlags
  module Generators
    # `rails g standard_flags:migrations` writes the migrations for runtime
    # rules: one creating the runtime-rule tables (rules, cohorts,
    # memberships and the single-row state), and one creating the compat
    # stats table (config.track_compat). Keys are UUIDs when the app
    # generates UUID primary keys.
    #
    # Each is skipped when a migration with the same name already exists, or
    # when its table already exists in the app's database (an app that
    # squashed or deleted the original migration), so running it again
    # after an upgrade adds only the new, additive one. `--no-check-tables`
    # skips the database check.
    class MigrationsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      MIGRATION_NAME = "create_standard_flags_tables".freeze
      COMPAT_MIGRATION_NAME = "create_standard_flags_compat_stats".freeze
      MIGRATION_NAMES = [ MIGRATION_NAME, COMPAT_MIGRATION_NAME ].freeze
      # The table each migration creates (the first of several, for the
      # runtime-rule tables).
      TABLES = { MIGRATION_NAME => "standard_flags_rules", COMPAT_MIGRATION_NAME => "standard_flags_compat_stats" }.freeze

      class_option :check_tables, type: :boolean, default: true,
                                  desc: "Skip a migration whose table already exists in the database"

      # Whether `table` exists in the app's database; false when there is no
      # connection to ask.
      def self.table_present?(table)
        ActiveRecord::Base.with_connection { |connection| connection.data_source_exists?(table) }
      rescue StandardError
        false
      end

      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Writes the migration for StandardFlags runtime rules. Run
        bin/rails db:migrate, then set config.runtime_rules = true.
      DESC

      def create_migration_file
        MIGRATION_NAMES.each do |name|
          if self.class.migration_exists?(File.join(destination_root, db_migrate_path), name)
            say_status("skip", "#{name} already present, skipping", :yellow)
            next
          end
          if options[:check_tables] && self.class.table_present?(TABLES.fetch(name))
            say_status("skip", "#{TABLES.fetch(name)} already exists in the database, skipping #{name}", :yellow)
            next
          end

          migration_template "#{name}.rb.tt", File.join(db_migrate_path, "#{name}.rb")
        end
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def uuid?
        primary_key_type.to_s == "uuid"
      end

      def primary_key_type
        generators = ::Rails.application&.config&.generators
        generators&.options&.dig(:active_record, :primary_key_type)
      end

      # `, id: :uuid` when the app generates UUID keys.
      def table_options
        uuid? ? ", id: :uuid" : ""
      end

      def foreign_key_type
        uuid? ? ":uuid" : ":bigint"
      end
    end
  end
end
