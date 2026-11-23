require "rails/generators"
require "pathname"

module StandardFlags
  module Generators
    # `rails g standard_flags:admin` writes an operator page the app owns:
    #
    # * a controller (default Admin::FlagsController < ApplicationController)
    #   with index, show and one action per operation. Pages read through
    #   StandardFlags::MCP, so `config.authorize` decides who sees what and
    #   unit keys stay masked; changes go through StandardFlags::Operations.
    #   It runs as the signed-in user (`--actor-method`, default
    #   current_user) and answers 401 when there is none, never falling back
    #   to config.actor_resolver.
    # * routes under a path (default /admin/flags).
    # * two Inertia pages, standard_flags/index.tsx and show.tsx, in plain
    #   semantic markup, typed from the `standard_flags:typescript` output.
    #
    # Restyle, move or cut down what it writes; the gem never reads it back.
    class AdminGenerator < Rails::Generators::Base
      OPERATIONS = %w[start pause stop ramp set_value add_members remove_members].freeze

      source_root File.expand_path("templates", __dir__)

      class_option :path, type: :string, default: "/admin/flags", desc: "Where the routes are mounted"
      class_option :base_controller, type: :string, default: "ApplicationController",
        desc: "The class the controller inherits from (where your admin authentication lives)"
      class_option :controller, type: :string, default: nil,
        desc: "The controller's name (default: from --path, e.g. Admin::FlagsController)"
      class_option :pages_path, type: :string, default: "app/javascript/pages", desc: "Where your Inertia pages live"
      class_option :actor_method, type: :string, default: "current_user",
        desc: "The controller method returning the signed-in user (nil when signed out: the page answers 401)"

      desc <<~DESC
        Writes an admin page for flags: a controller, routes and two Inertia
        pages (TSX). Run bin/rails standard_flags:typescript for the types
        they import, then restyle the pages to fit your app.
      DESC

      def check_options
        actor_method
      end

      def create_controller
        template "controller.rb.tt", File.join("app/controllers", "#{controller_path}_controller.rb")
      end

      def add_routes
        route routes_block
      end

      def create_pages
        template "index.tsx.tt", File.join(options[:pages_path], "standard_flags/index.tsx")
        template "show.tsx.tt", File.join(options[:pages_path], "standard_flags/show.tsx")
      end

      def explain
        say "Admin page: #{mount_path}. It runs as `#{actor_method}` through config.authorize, so configure that " \
            "first; with nobody signed in it answers 401 (see standard_flags_deny). Run bin/rails " \
            "standard_flags:typescript for its types."
        say "Unit keys are posted as `unit_keys`, which Rails' default config.filter_parameters (`_key`) keeps " \
            "out of the request log. If your app's list doesn't match it, add :unit_keys."
      end

      private

      # "/admin/flags", without a trailing slash.
      def mount_path
        "/#{options[:path].to_s.delete_prefix('/').delete_suffix('/')}"
      end

      # "admin/flags"
      def controller_path
        return options[:controller].to_s.delete_suffix("Controller").underscore if options[:controller]

        mount_path.delete_prefix("/").tr("-", "_")
      end

      # "Admin::FlagsController"
      def controller_class
        "#{controller_path.camelize}Controller"
      end

      def base_controller
        options[:base_controller]
      end

      def actor_method
        name = options[:actor_method].to_s
        raise Thor::Error, "--actor-method must be a method name, got #{name.inspect}" unless name.match?(/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/)

        name
      end

      def routes_block
        lines = [ "# StandardFlags admin (bin/rails g standard_flags:admin)",
                  "scope path: #{mount_path.inspect}, controller: #{controller_path.inspect}, as: :standard_flags do",
                  "  get \"/\", action: :index, as: :flags",
                  "  get \"/:id\", action: :show, as: :flag" ]
        OPERATIONS.each { |operation| lines << "  post \"/:id/#{operation}\", action: :#{operation}, as: :#{operation}_flag" }
        lines << "end"
        lines.join("\n")
      end

      # The import path from the pages to the generated .d.ts, without its
      # extension: "../../types/standard_flags".
      def types_import
        target = Pathname(StandardFlags.config.typescript_path.to_s.delete_suffix(".d.ts").delete_suffix(".ts"))
        from = Pathname(File.join(options[:pages_path], "standard_flags"))
        relative = target.relative_path_from(from).to_s
        relative.start_with?(".") ? relative : "./#{relative}"
      end
    end
  end
end
