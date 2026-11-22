require "rails/generators"

module StandardFlags
  module Generators
    # `rails g standard_flags:install` writes:
    #
    # * config/initializers/standard_flags.rb — runtime settings, commented.
    # * config/flags.rb — the registry, with one commented example per kind.
    #
    # Idempotent: existing files are skipped. Pass --force to overwrite.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Installs StandardFlags: writes config/initializers/standard_flags.rb
        and config/flags.rb with commented examples. Existing files are
        skipped; pass --force to overwrite.
      DESC

      def create_initializer_file
        write_template("initializer.rb.tt", "config/initializers/standard_flags.rb")
      end

      def create_registry_file
        write_template("flags.rb.tt", "config/flags.rb")
      end

      private

      def write_template(source, path)
        if File.exist?(File.join(destination_root, path)) && !options[:force]
          say_status("skip", "#{path} already present, skipping (use --force to overwrite)", :yellow)
          return
        end

        template source, path
      end
    end
  end
end
