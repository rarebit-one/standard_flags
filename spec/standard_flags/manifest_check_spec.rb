require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe StandardFlags::Tooling::ManifestCheck do
  let(:today) { Date.new(2027, 2, 1) }
  let!(:shipped) do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: %i[chat chatEnabled], web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end
  end

  def declare(&block)
    define_flags(&block)
    StandardFlags::Tooling::Manifest.new.render
  end

  def check(committed:, **options)
    described_class.new(committed: committed, today: today, **options)
  end


  it "passes when the committed manifest matches the registry" do
    result = check(committed: shipped).call

    expect([ result.status, result.ok?, result.stale, result.exit_code, result.findings ]).to eq([ :ok, true, false, 0, [] ])
    expect(check(committed: shipped).render(result, path: "config/flags.manifest.json"))
      .to eq("standard_flags:manifest:check OK: config/flags.manifest.json matches the registry")
  end

  it "reports a missing manifest as stale (exit 1)" do
    result = check(committed: nil).call
    expect([ result.status, result.exit_code ]).to eq([ :missing, 1 ])
    expect(check(committed: nil).render(result, path: "config/flags.manifest.json")).to eq(<<~TEXT.chomp)
      standard_flags:manifest:check: config/flags.manifest.json does not exist
      Run bin/rails standard_flags:manifest and commit the result.
    TEXT
  end

  it "reports a stale manifest with what changed (exit 1)" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: %i[chat chatEnabled insights], web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }, default: "savings"
      flag :new_checkout, owner: "payments", remove_by: "2027-06-01", final: true
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end
    subject = check(committed: shipped)
    result = subject.call

    expect([ result.status, result.exit_code, result.findings ]).to eq([ :stale, 1, [] ])
    expect(subject.render(result, path: "config/flags.manifest.json")).to eq(<<~TEXT.chomp)
      standard_flags:manifest:check: config/flags.manifest.json is stale:
        ~ flag :ai_assistant: audiences {"mobile":["chat","chatEnabled"],"web":["assistant"]} → {"mobile":["chat","chatEnabled","insights"],"web":["assistant"]}
        ~ flag :home_hero: default "control" → "savings"
        + flag :new_checkout
      Run bin/rails standard_flags:manifest and commit the result.
    TEXT
  end

  it "says when only the bytes differ" do
    reformatted = JSON.generate(JSON.parse(shipped))
    result = check(committed: reformatted).call

    expect([ result.status, result.changes ])
      .to eq([ :stale, [ "the content is identical but the bytes differ; regenerate instead of editing by hand" ] ])
    expect(check(committed: JSON.parse(shipped)).call.status).to eq(:ok)
  end

  it "fails on a wire dropped without a tombstone serving it (exit 2), even when the file was regenerated" do
    regenerated = declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chatEnabled, web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end

    expect(check(committed: regenerated).call.status).to eq(:ok)

    subject = check(committed: regenerated, base: shipped)
    result = subject.call
    expect([ result.status, result.stale, result.exit_code ]).to eq([ :breaking, false, 2 ])
    expect(result.removed_wires.map(&:to_h)).to eq([ { "audience" => "mobile", "wire" => "chat" } ])
    expect(subject.render(result)).to eq(<<~TEXT.chomp)
      standard_flags:manifest:check: the client contract is broken:
        removed wire: mobile.chat (flag :ai_assistant) is gone and no tombstone serves it; keep it exposed, or add serve: { mobile: { chat: <value> } }, until: "YYYY-MM-DD" to the tombstone
    TEXT
  end

  it "accepts a removed flag whose wires a tombstone serves, and a deprecated wire whose window is over" do
    declare do
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :ai_assistant, removed: "2027-01-15", serve: { mobile: { chat: false, chatEnabled: false }, web: { assistant: false } },
                               until: "2027-06-01"
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01"
    end
    result = check(committed: shipped).call

    expect([ result.status, result.findings ]).to eq([ :stale, [] ])
  end

  it "fails when a deprecated wire's serve: block goes before its until: date" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: %i[chat chatEnabled], web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01"
      tombstone :banner_v1, removed: "2026-06-01"
    end
    result = check(committed: shipped).call

    expect(result.removed_wires.map(&:to_h)).to eq([ { "audience" => "mobile", "wire" => "chat_v1" } ])
    expect(result.removed_wires.first.detail).to include("mobile.chat_v1 (tombstone :chat_v1, until 2027-03-01) is gone")
    expect(check(committed: shipped, today: Date.new(2027, 3, 2)).call.findings).to eq([])
  end

  it "fails when the only tombstone serving a wire has stopped serving it" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chatEnabled, web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false, chat: false } }, until: "2027-01-31"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end
    result = check(committed: shipped).call

    expect(result.removed_wires.map(&:to_h)).to eq([ { "audience" => "mobile", "wire" => "chat" }, { "audience" => "mobile", "wire" => "chat_v1" } ])
    expect(result.removed_wires.first.detail)
      .to eq("removed wire: mobile.chat is served by tombstone :chat_v1 only through 2027-01-31, which has passed")
  end

  it "fails on a wire that changed type" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: %i[chat chatEnabled], web: :assistant }
      flag :home_hero, owner: "growth", remove_by: "2027-06-01", final: true, expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: "off" } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end
    subject = check(committed: shipped)
    result = subject.call

    expect([ result.status, result.stale, result.exit_code ]).to eq([ :breaking, true, 2 ])
    expect(result.type_changes.map(&:to_h)).to eq([
      { "audience" => "mobile", "wire" => "chat_v1", "from" => "boolean", "to" => "string" },
      { "audience" => "mobile", "wire" => "homeHero", "from" => "string", "to" => "boolean" }
    ])
    expect(subject.render(result)).to eq(<<~TEXT.chomp)
      standard_flags:manifest:check: the client contract is broken:
        type changed: mobile.chat_v1 was boolean and is now string
        type changed: mobile.homeHero was string and is now boolean
      standard_flags:manifest:check: the committed manifest is stale:
        ~ flag :home_hero: kind "experiment" → "flag"; type "string" → "boolean"; values ["control","savings"] → [true,false]; default "control" → false; permanent (none) → false; remove_by (none) → "2027-06-01"; final (none) → true
        ~ tombstone :chat_v1: serve {"mobile":{"chat_v1":false}} → {"mobile":{"chat_v1":"off"}}
      Run bin/rails standard_flags:manifest and commit the result.
    TEXT
  end

  it "lets a wire move to another flag of the same type" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chatEnabled, web: :assistant }
      kill_switch :chat, owner: "assistant", expose: { mobile: :chat }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end

    expect(check(committed: shipped).call.findings).to eq([])
  end

  it "upgrades a version 1 committed manifest: stale, with the contract still checked" do
    v1 = {
      "version" => 1,
      "flags" => [
        { "key" => "ai_assistant", "kind" => "kill_switch", "type" => "boolean", "values" => [ true, false ], "default" => true,
          "audiences" => { "mobile" => "chat", "web" => "assistant" }, "wires" => { "mobile" => %w[chat chatEnabled legacyChat], "web" => %w[assistant] } },
        { "key" => "gone_flag", "kind" => "flag", "type" => "boolean", "values" => [ true, false ], "default" => false,
          "audiences" => {}, "permanent" => true }
      ],
      "tombstones" => []
    }
    subject = check(committed: "#{JSON.pretty_generate(v1)}\n")
    result = subject.call

    expect(result.status).to eq(:breaking)
    expect(result.removed_wires.map(&:to_h)).to eq([ { "audience" => "mobile", "wire" => "legacyChat" } ])
    expect(result.changes).to eq([
      "~ version: 1 → 2 (regenerating upgrades the format)",
      "+ audiences",
      "~ flag :ai_assistant",
      "- flag :gone_flag",
      "+ flag :home_hero",
      "+ tombstone :banner_v1",
      "+ tombstone :chat_v1"
    ])
  end

  it "skips the contract check against a base that doesn't exist yet" do
    result = check(committed: shipped, base: nil).call
    expect(result.status).to eq(:ok)
  end

  it "reports an unreadable manifest (exit 2)" do
    subject = check(committed: "{not json")
    result = subject.call

    expect([ result.status, result.exit_code, result.error ]).to match([ :unreadable, 2, /not valid JSON/ ])
    expect(subject.render(result)).to start_with("standard_flags:manifest:check: can't read a manifest: the manifest is not valid JSON")
    expect(check(committed: shipped, base: '{"version":9}').call.error).to eq("unknown manifest version 9 (this gem reads 1 and 2)")
  end

  describe ".changes" do
    it "lists top-level entries added, removed and changed" do
      old = { "version" => 2, "audiences" => { "web" => { "public" => false }, "kiosk" => { "public" => false } }, "extra" => [ 1 ] }
      new = { "version" => 2, "audiences" => { "web" => { "public" => true }, "mobile" => { "public" => false } }, "clients" => [] }

      expect(described_class.changes(old, new)).to eq([
        "- audiences.kiosk", "+ audiences.mobile", '~ audiences.web: {"public":false} → {"public":true}', "+ clients", "- extra"
      ])
      expect(described_class.changes({ "version" => 2, "x" => 1 }, { "version" => 2, "x" => 2 })).to eq([ "~ x: 1 → 2" ])
      expect(described_class.changes({ "version" => 2, "flags" => [ { "key" => "a", "kind" => "flag" } ] },
                                     { "version" => 2, "flags" => [ { "key" => "a", "kind" => "flag", "final" => true } ] }))
        .to eq([ "~ flag :a: final (none) → true" ])
    end
  end

  describe "the rake task" do
    let(:root) { Pathname(Dir.mktmpdir) }

    before { allow(Rails).to receive(:root).and_return(root) }

    after do
      FileUtils.rm_rf(root)
      ENV.delete("BASE")
    end

    def run(base: nil)
      ENV["BASE"] = base if base
      RakeTasks.invoke("standard_flags:manifest:check")
      0
    rescue SystemExit => e
      e.status
    end

    def write_manifest
      expect { RakeTasks.invoke("standard_flags:manifest") }.to output(/Wrote/).to_stdout
    end

    it "exits 1 when there is no committed manifest" do
      expect { expect(run).to eq(1) }.to output(/does not exist/).to_stderr
    end

    it "exits 0 when the committed manifest is current" do
      write_manifest
      expect { expect(run).to eq(0) }.to output(%r{OK: config/flags.manifest.json matches the registry}).to_stdout
    end

    it "exits 1 when the committed manifest is stale" do
      write_manifest
      File.write(root.join("config/flags.manifest.json"), "#{shipped} ")
      expect { expect(run).to eq(1) }.to output(/is stale/).to_stderr
    end

    it "exits 2 on a wire BASE told a client that is gone, and checks only staleness when BASE doesn't exist" do
      write_manifest
      File.write(root.join("base.json"), shipped.sub('"chatEnabled"', %("chatEnabled",\n          "legacyChat")))
      expect { expect(run(base: root.join("base.json").to_s)).to eq(2) }.to output(/removed wire: mobile.legacyChat/).to_stderr
      expect { expect(run(base: root.join("missing.json").to_s)).to eq(0) }.to output(/OK/).to_stdout
    end

    it "writes the Kotlin file" do
      expect { RakeTasks.invoke("standard_flags:kotlin") }.to output(%r{Wrote config/StandardFlags.kt}).to_stdout
      expect(root.join("config/StandardFlags.kt").read).to include("enum class MobileFeature(")
    end
  end
end
