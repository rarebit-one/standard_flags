require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe StandardFlags::Tooling do
  before do
    define_flags do
      env_resolver -> { "production" }
      flag :new_checkout, owner: "payments", remove_by: "2027-03-01", final: true,
           default: { staging: true, production: false }, expose: { web: :newCheckout }
      flag :old_banner, owner: "growth", remove_by: "2020-01-01", final: false
      flag :demo_pages, owner: "platform", permanent: true, default: { development: true }, forbidden_in: :production
      kill_switch :ai_assistant, owner: "assistant", env: "ACME_LEGACY_DISABLED", inverted: true,
                  expose: { web: :assistant, mobile: :chat }
      mode :strict_gates, owner: "platform", preset: :sensor, expose: { web: :strict_gates }
      experiment :home_hero, owner: "growth", variants: %w[control savings]
      tombstone :manual_entry, removed: "2026-12-01"
    end
  end

  describe StandardFlags::Tooling::List do
    it "renders key, kind, value, reason, env var and remove_by" do
      set_env("ACME_LEGACY_DISABLED" => "true")
      lines = described_class.new.render.lines.map(&:split)

      expect(lines.first).to eq(%w[key kind value reason env_var remove_by])
      expect(lines).to include(%w[ai_assistant kill_switch false KILL_SWITCH ACME_LEGACY_DISABLED -])
      expect(lines).to include(%w[new_checkout flag false DEFAULT - 2027-03-01])
      expect(lines).to include(%w[strict_gates mode off DEFAULT - -])
      expect(lines).to include(%w[demo_pages flag false DISABLED - permanent])
    end
  end

  describe StandardFlags::Tooling::Stale do
    it "lists flags past remove_by with their final value, never permanent ones" do
      expect(described_class.new(today: Date.new(2026, 1, 1)).render)
        .to eq("old_banner (flag, owner: growth) was due for removal on 2020-01-01, final: false")
    end

    it "says so when nothing is stale" do
      expect(described_class.new(today: Date.new(2019, 1, 1)).render).to eq("No flags are past their remove_by date.")
    end
  end

  describe StandardFlags::Tooling::Refs do
    let(:root) { Dir.mktmpdir }

    after { FileUtils.rm_rf(root) }

    def write(path, content)
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    it "fails on undeclared and tombstoned keys and warns on unreferenced flags" do
      write "app/controllers/checkout_controller.rb", <<~RUBY
        class CheckoutController
          requires_flag :new_checkout
          def show = StandardFlags.on?(:typo_flag) || StandardFlags.mode("strict_gates").on?
        end
      RUBY
      write "app/views/home/index.html.erb", %(<% if StandardFlags.variant(:home_hero) == "savings" %><% end %>)
      write "lib/tasks/cleanup.rake", %(StandardFlags.off?(:manual_entry))
      write "config/flags.rb", %(# StandardFlags.on?(:only_in_registry_comment))

      refs = described_class.new(root: root)
      result = refs.call

      expect(result).to be_failed
      expect(result.undeclared).to eq(manual_entry: [ "lib/tasks/cleanup.rake:1" ], typo_flag: [ "app/controllers/checkout_controller.rb:3" ])
      expect(result.unreferenced).to eq(%i[ai_assistant demo_pages old_banner])
      expect(refs.render(result)).to include("ERROR tombstoned flag :manual_entry", "ERROR undeclared flag :typo_flag",
                                             "WARN  declared flag :ai_assistant has no references")
    end

    it "passes when every reference is declared" do
      write "app/models/order.rb", %(StandardFlags.evaluate(:new_checkout); StandardFlags.peek(:ai_assistant))
      refs = described_class.new(root: root, paths: %w[app])
      result = refs.call
      expect(result).not_to be_failed
      expect(refs.render(described_class::Result.new(references: { a: [] }, undeclared: {}, unreferenced: [])))
        .to eq("flags:refs OK (1 keys referenced)")
    end
  end

  describe StandardFlags::Tooling::Manifest do
    it "is deterministic JSON with wire names, kinds, values, audiences and defaults" do
      manifest = JSON.parse(described_class.new.render)

      expect(manifest.values_at("version", "flags").then { |v, flags| [ v, flags.map { |f| f["key"] } ] })
        .to eq([ 1, %w[ai_assistant demo_pages home_hero new_checkout old_banner strict_gates] ])
      expect(manifest["flags"].find { |f| f["key"] == "ai_assistant" }).to eq(
        "key" => "ai_assistant", "kind" => "kill_switch", "type" => "boolean", "values" => [ true, false ],
        "default" => true, "audiences" => { "mobile" => "chat", "web" => "assistant" }
      )
      expect(manifest["flags"].find { |f| f["key"] == "new_checkout" }["default"])
        .to eq("*" => false, "production" => false, "staging" => true)
      expect(manifest["tombstones"]).to eq([ { "key" => "manual_entry", "removed" => "2026-12-01" } ])
      expect(described_class.new.render).to eq(described_class.new.render).and(end_with("}\n"))
    end

    it "says whether each entry of kind flag is permanent" do
      flags = JSON.parse(described_class.new.render)["flags"].to_h { |f| [ f["key"], f ] }

      expect(flags.transform_values { |f| f.fetch("permanent", :absent) })
        .to include("demo_pages" => true, "new_checkout" => false, "ai_assistant" => :absent)
      expect(flags["demo_pages"]).to eq(
        "key" => "demo_pages", "kind" => "flag", "type" => "boolean", "values" => [ true, false ],
        "default" => { "*" => false, "development" => true }, "audiences" => {}, "permanent" => true
      )
    end
  end

  describe StandardFlags::Tooling::TypeScript do
    it "emits one Features interface per audience" do
      define_flags do
        kill_switch :ai_assistant, owner: "x", expose: { web: :assistant, mobile: :chat }
        mode :strict_gates, owner: "x", preset: :sensor, expose: { web: :strictGates }
        flag :new_checkout, owner: "x", remove_by: "2027-01-01", final: true
      end

      expect(described_class.new.render).to eq(<<~TS)
        // Generated by `bin/rails standard_flags:typescript`. Do not edit by hand.

        export interface MobileFeatures {
          readonly chat: boolean;
        }

        export interface WebFeatures {
          readonly assistant: boolean;
          readonly strictGates: "off" | "sensor" | "on";
        }

        export type FeaturesByAudience = {
          mobile: MobileFeatures;
          web: WebFeatures;
        };
      TS
    end
  end

  describe "rake tasks" do
    let(:root) { Pathname(Dir.mktmpdir) }

    before { allow(Rails).to receive(:root).and_return(root) }

    after { FileUtils.rm_rf(root) }

    def run_task(name)
      RakeTasks.invoke(name)
    end

    it "lists, reports stale flags and writes the manifest and types" do
      expect { run_task("flags:list") }.to output(/new_checkout/).to_stdout
      expect { run_task("flags:stale") }.to output(/old_banner/).to_stdout
      expect { run_task("standard_flags:manifest") }.to output(%r{Wrote config/flags.manifest.json}).to_stdout
      expect { run_task("standard_flags:typescript") }.to output(/standard_flags\.d\.ts/).to_stdout
      expect(root.join("config/flags.manifest.json")).to exist
    end

    it "exits non-zero from flags:refs on an undeclared key" do
      FileUtils.mkdir_p(root.join("app"))
      File.write(root.join("app/x.rb"), "StandardFlags.on?(:typo_flag)")
      expect { expect { run_task("flags:refs") }.to raise_error(SystemExit) }.to output(/typo_flag/).to_stdout
    end
  end
end
