require "spec_helper"
require "fileutils"
require "open3"
require "stringio"
require "rack/test"
require "rails/generators"
require "generators/standard_flags/admin/admin_generator"

# The base the booted spec controller inherits from: where a host keeps its
# admin authentication. `X-User` names the signed-in user's id.
class AdminSpecBaseController < ActionController::Base
  skip_forgery_protection

  private

  def current_user
    id = request.headers["X-User"]
    OperationHelpers::User.new(id.to_i) if id
  end
end

# Generates an admin page once, loads its controller and adds its routes to
# the dummy app (alongside the others), as a host boots it. `render
# inertia:` answers the way inertia_rails answers an X-Inertia request: the
# component and its props, as JSON.
module AdminSpecBoot
  module_function

  def boot!
    return if defined?(::SpecAdmin::FlagsController)

    ActionController::Renderers.add(:inertia) { |component, options| render json: { component: component, props: options[:props] } }
    root = File.expand_path("../../tmp/admin_boot", __dir__)
    write_app(root)
    Object.const_set(:SpecAdmin, Module.new) unless defined?(::SpecAdmin)
    load File.join(root, "app/controllers/spec_admin/flags_controller.rb")
    add_routes(File.join(root, "config/routes.rb"))
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write_app(root)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    DatabaseHelpers.capture_stdout do
      StandardFlags::Generators::AdminGenerator.start([ "--path=/spec-admin/flags", "--base-controller=AdminSpecBaseController",
                                                        "--controller=SpecAdmin::FlagsController" ], destination_root: root)
    end
  end

  # Draws the generated routes without clearing the dummy app's.
  def add_routes(file)
    routes = Rails.application.routes
    routes.disable_clear_and_finalize = true
    load file
  ensure
    routes.disable_clear_and_finalize = false
  end
end

RSpec.describe StandardFlags::Generators::AdminGenerator, type: :generator do
  let(:destination_root) { File.expand_path("../../tmp/admin_dest", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.rm_rf(destination_root) }

  def generate(*args)
    original = $stdout
    $stdout = StringIO.new
    described_class.start(args, destination_root: destination_root)
    $stdout.string
  ensure
    $stdout = original
  end

  def read(path)
    File.read(File.join(destination_root, path))
  end

  describe "what it writes" do
    it "writes a controller, routes and two pages with the defaults" do
      output = generate
      expect(output).to include("Admin page: /admin/flags. It runs as `current_user`", "answers 401",
                                "Unit keys are posted as `unit_keys`", "add :unit_keys")

      controller = read("app/controllers/admin/flags_controller.rb")
      expect(controller).to include("class Admin::FlagsController < ApplicationController", 'BASE_PATH = "/admin/flags".freeze',
                                    'tool("list_flags")', 'tool("get_flag"', 'tool("list_members"', "StandardFlags::AuditTrail.available?",
                                    "ACTOR_METHOD = :current_user", "before_action :require_standard_flags_actor",
                                    "head :unauthorized", "params[:unit_keys]",
                                    *described_class::OPERATIONS.map { |operation| "  def #{operation} = change(StandardFlags::Operations::" })

      expect(read("config/routes.rb")).to include(
        'scope path: "/admin/flags", controller: "admin/flags", as: :standard_flags do',
        'get "/", action: :index, as: :flags', 'get "/:id", action: :show, as: :flag',
        *described_class::OPERATIONS.map { |operation| %(post "/:id/#{operation}", action: :#{operation}, as: :#{operation}_flag) }
      )
    end

    # CI has no TypeScript toolchain, so these assert the pages' structure;
    # the example below type-checks them when one is available.
    it "writes Inertia pages typed from the generated TypeScript, in plain markup" do
      generate
      index = read("app/javascript/pages/standard_flags/index.tsx")
      show = read("app/javascript/pages/standard_flags/show.tsx")
      [ index, show ].each do |page|
        expect(page).to include('from "../../types/standard_flags";', 'from "@inertiajs/react";', "export default function")
        expect(page).not_to match(/className=|tailwind|styled|\.css/)
      end
      expect(index).to include("import type { FlagList, FlagSummary }", "<table>", "<th scope=\"col\">Flag</th>", "flag.pinned.label")
      expect(show).to include('{ name: "unit_keys", label: "Unit keys', "import type { FlagAuditEntry, FlagDetail, FlagMemberPage }", "useForm", "expected_revision",
                              "flag.pinned === null", "{flag.pinned.label}", "Recent changes", "members_offset",
                              *described_class::OPERATIONS.map { |operation| %(action("#{operation}")) })
      expect(StandardFlags::Tooling::TypeScript::MCP_TYPES)
        .to include(*%w[FlagList FlagSummary FlagAuditEntry FlagDetail FlagMemberPage].map { |type| "export interface #{type} " })
    end

    it "takes a path, a base controller, a controller name and a pages path" do
      generate("--path=/ops/feature-flags/", "--base-controller=Ops::BaseController", "--pages-path=app/frontend/pages")
      expect(read("app/controllers/ops/feature_flags_controller.rb")).to include("class Ops::FeatureFlagsController < Ops::BaseController",
                                                                                 'BASE_PATH = "/ops/feature-flags".freeze')
      expect(read("config/routes.rb")).to include('scope path: "/ops/feature-flags", controller: "ops/feature_flags"')
      expect(read("app/frontend/pages/standard_flags/index.tsx")).to include('from "../../../javascript/types/standard_flags";')

      generate("--controller=Staff::TogglesController")
      expect(read("app/controllers/staff/toggles_controller.rb")).to include("class Staff::TogglesController < ApplicationController")
    end

    it "takes the method that returns the signed-in user, and refuses one that isn't a method name" do
      expect { generate("--actor-method=current_user; system('x')") }.to output(/must be a method name/).to_stderr
      expect(File.exist?(File.join(destination_root, "app/controllers/admin/flags_controller.rb"))).to be(false)
      generate("--actor-method=current_admin")
      expect(read("app/controllers/admin/flags_controller.rb")).to include("ACTOR_METHOD = :current_admin")
    end

    it "imports the types from config.typescript_path" do
      StandardFlags.config.typescript_path = "types/flags.ts"
      generate
      expect(read("app/javascript/pages/standard_flags/show.tsx")).to include('from "../../../../types/flags";')
      StandardFlags.config.typescript_path = "app/javascript/pages/standard_flags/flags.d.ts"
      generate("--force")
      expect(read("app/javascript/pages/standard_flags/show.tsx")).to include('from "./flags";')
    end

    it "type-checks with tsc --noEmit when STANDARD_FLAGS_TSC_NODE_MODULES points at typescript, react and @inertiajs/react" do
      node_modules = ENV["STANDARD_FLAGS_TSC_NODE_MODULES"]
      skip "set STANDARD_FLAGS_TSC_NODE_MODULES to type-check the pages" unless node_modules && File.exist?(File.join(node_modules, ".bin/tsc"))

      generate
      types = File.join(destination_root, "app/javascript/types/standard_flags.d.ts")
      FileUtils.mkdir_p(File.dirname(types))
      define_flags { mode :strict_gates, owner: "x", preset: :sensor }
      File.write(types, StandardFlags::Tooling::TypeScript.new.render)
      File.symlink(node_modules, File.join(destination_root, "node_modules"))
      File.write(File.join(destination_root, "tsconfig.json"), JSON.generate(
        compilerOptions: { strict: true, noEmit: true, jsx: "react-jsx", module: "esnext", moduleResolution: "bundler",
                           target: "es2022", skipLibCheck: true, noUnusedLocals: true, noUnusedParameters: true },
        include: [ "app/javascript/**/*" ]
      ))
      output, status = Open3.capture2e(File.join(node_modules, ".bin/tsc"), "-p", "tsconfig.json", chdir: destination_root)
      expect(status).to be_success, output
    end
  end

  describe "the generated page, booted" do
    include Rack::Test::Methods

    let(:store) { StandardFlags::Runtime::MemoryStore.new }

    before do
      AdminSpecBoot.boot!
      define_flags(&OperationHelpers::REGISTRY)
      StandardFlags.config.runtime_rules = true
      StandardFlags.config.runtime_store = store
      # User 1 may do anything; user 2 may only read.
      StandardFlags.config.authorize = ->(actor, scope, _key) { actor&.id == 1 || (actor&.id == 2 && scope == "flags:read") }
      header "X-User", "1"
    end

    def app
      Rails.application
    end

    def page
      JSON.parse(last_response.body)
    end

    it "lists the flags" do
      get "/spec-admin/flags"
      expect(last_response.status).to eq(200)
      expect(page["component"]).to eq("standard_flags/index")
      expect(page["props"]).to include("base_path" => "/spec-admin/flags", "flash" => {})
      expect(page["props"]["flags"]["flags"].map { |f| f["key"] }).to include("new_checkout", "strict_gates")
    end

    it "shows a flag with its members masked, and changes it through an operation" do
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "acct-7731", value: true)

      get "/spec-admin/flags/new_checkout"
      expect(page).to include("component" => "standard_flags/show",
                              "props" => include("flag" => include("key" => "new_checkout", "pinned" => nil), "audit" => nil,
                                                 "members" => include("total" => 1, "members" => [ include("unit_key" => "•••7731") ])))
      expect_no_unit_keys(last_response.body)

      post "/spec-admin/flags/new_checkout/ramp", { bps: "500", reason: "canary", expected_revision: "0" }
      expect([ last_response.status, URI(last_response.location).path, store.rule(:new_checkout).percentage_bps ])
        .to eq([ 302, "/spec-admin/flags/new_checkout", 500 ])

      follow_redirect!
      expect(page["props"]["flash"]).to eq("notice" => "Ramp: done (revision 1)")
      expect(page["props"]["flag"]["rule"]).to include("percentage_bps" => 500, "revision" => 1)
    end

    it "runs every operation's action" do
      post "/spec-admin/flags/new_checkout/add_members", { unit_keys: "acct-7731, acct-7732\nacct-7733", reason: "pilot" }
      post "/spec-admin/flags/new_checkout/remove_members", { unit_keys: "acct-7733", reason: "done" }
      post "/spec-admin/flags/new_checkout/start", { reason: "go" }
      post "/spec-admin/flags/new_checkout/pause", { reason: "hold" }
      post "/spec-admin/flags/strict_gates/set_value", { value: "on", reason: "go" }
      post "/spec-admin/flags/home_hero/stop", { serve: "savings", reason: "won" }
      expect(store.members(rule: :new_checkout).memberships.map(&:unit_key)).to eq(%w[acct-7731 acct-7732])
      expect(store.rule(:new_checkout).status).to eq("paused")
      expect(store.rule(:strict_gates).fallthrough_value).to eq("on")
      expect(store.rule(:home_hero)).to have_attributes(status: "stopped", stop_value: "savings")
    end

    it "flashes a refusal: a stale revision, a missing reason, a bad number" do
      post "/spec-admin/flags/new_checkout/ramp", { bps: "500", reason: "canary", expected_revision: "3" }
      follow_redirect!
      expect(page["props"]["flash"]["alert"]).to start_with("Ramp refused (stale_revision)")
      post "/spec-admin/flags/new_checkout/start", {}
      follow_redirect!
      expect(page["props"]["flash"]["alert"]).to eq("Start refused (invalid): a reason is required")
      post "/spec-admin/flags/new_checkout/ramp", { bps: "lots", reason: "x" }
      follow_redirect!
      expect(page["props"]["flash"]["alert"]).to include("invalid value for Integer")
    end

    it "shows a pinned flag read-only, labelled, and refuses to change it" do
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "on" }
      get "/spec-admin/flags/new_checkout"
      expect(page["props"]["flag"]["pinned"]).to eq("env_var" => "STANDARD_FLAGS_NEW_CHECKOUT",
                                                    "label" => "Pinned by environment (STANDARD_FLAGS_NEW_CHECKOUT)")
      post "/spec-admin/flags/new_checkout/pause", { reason: "x" }
      follow_redirect!
      expect(page["props"]["flash"]["alert"]).to start_with("Pause refused (pinned_by_env)")
    end

    it "shows recent audit entries when standard_audit is loaded" do
      entries = [ { event: "standard_flags.flag.ramped", occurred_at: "2026-11-23T09:00:00Z", actor: "User:1", reason: "canary", revision: 1 } ]
      allow(StandardFlags::AuditTrail).to receive_messages(available?: true, new: instance_double(StandardFlags::AuditTrail, entries: entries))
      get "/spec-admin/flags/global_banner"
      expect(page["props"]["audit"]).to eq([ entries.first.transform_keys(&:to_s) ])
      expect(page["props"]["members"]).to be_nil
    end

    # Rails' default filter_parameters (a new app's initializer) matches
    # `_key`, so the posted unit keys never reach the request log.
    it "keeps posted unit keys out of the request log" do
      filters = Rails.application.config.filter_parameters
      saved = filters.dup
      filters.replace(%i[passw email secret token _key crypt salt certificate otp ssn cvv cvc])
      log = StringIO.new
      logger = ActionController::Base.logger
      ActionController::Base.logger = Logger.new(log)
      post "/spec-admin/flags/phone_login/add_members", { unit_keys: "+6591234567, +6598765432", reason: "pilot" }
      expect(store.members(rule: :phone_login).total).to eq(2)
      expect(log.string).to include("Parameters:", '"unit_keys" => "[FILTERED]"')
      expect(log.string).not_to include("6591234567", "6598765432")
    ensure
      ActionController::Base.logger = logger
      filters&.replace(saved)
    end

    # A host's actor_resolver may return a system actor (for jobs and the
    # console); a signed-out request must never run as it.
    it "answers 401 to a signed-out request before any tool or operation runs, never using config.actor_resolver" do
      StandardFlags.config.actor_resolver = -> { StandardFlags::Actor.system("jobs") }
      StandardFlags.config.authorize = ->(*) { true }
      header "X-User", nil
      allow(StandardFlags::MCP).to receive(:tool).and_call_original
      get "/spec-admin/flags"
      expect(last_response.status).to eq(401)
      get "/spec-admin/flags/new_checkout"
      expect(last_response.status).to eq(401)
      post "/spec-admin/flags/new_checkout/pause", { reason: "x" }
      expect(last_response.status).to eq(401)
      expect(StandardFlags::MCP).not_to have_received(:tool)
      expect(store.rule(:new_checkout)).to be_nil
    end

    it "answers 403 to an actor who may not read, and 404 to an unknown flag" do
      header "X-User", "9"
      get "/spec-admin/flags"
      expect(last_response.status).to eq(403)
      get "/spec-admin/flags/new_checkout"
      expect(last_response.status).to eq(403)
      header "X-User", "1"
      get "/spec-admin/flags/nope"
      expect(last_response.status).to eq(404)
    end

    it "lets a read-only actor look but not change" do
      header "X-User", "2"
      get "/spec-admin/flags/new_checkout"
      expect(last_response.status).to eq(200)
      post "/spec-admin/flags/new_checkout/pause", { reason: "x" }
      follow_redirect!
      expect(page["props"]["flash"]["alert"]).to start_with("Pause refused (unauthorized)")
    end
  end
end
