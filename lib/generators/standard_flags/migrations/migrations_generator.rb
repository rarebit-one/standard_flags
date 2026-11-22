require "rails/generators"
require "rails/generators/active_record"

module StandardFlags
  module Generators
    # `rails g standard_flags:migrations` writes one migration creating the
    # runtime-rule tables (rules, cohorts, memberships and the single-row
    # state). Keys are UUIDs when the app generates UUID primary keys.
    #
    # Skipped when a migration with the same name already exists.
    class MigrationsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      MIGRATION_NAME = "create_standard_flags_tables".freeze

      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Writes the migration for StandardFlags runtime rules. Run
        bin/rails db:migrate, then set config.runtime_rules = true.
      DESC

      def create_migration_file
        if self.class.migration_exists?(File.join(destination_root, db_migrate_path), MIGRATION_NAME)
          say_status("skip", "#{MIGRATION_NAME} already present, skipping", :yellow)
          return
        end

        migration_template "#{MIGRATION_NAME}.rb.tt", File.join(db_migrate_path, "#{MIGRATION_NAME}.rb")
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
