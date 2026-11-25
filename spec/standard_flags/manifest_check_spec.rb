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

  # The committed file doubles as the baseline unless a test says otherwise,
  # passed explicitly so the no-BASE warning stays out of the output.
  def check(committed:, base: committed, **options)
    described_class.new(committed: committed, base: base, today: today, **options)
  end

  it "passes when the committed manifest matches the registry" do
    result = check(committed: shipped).call

    expect([ result.status, result.ok?, result.stale, result.exit_code, result.findings ]).to eq([ :ok, true, false, 0, [] ])
    expect(check(committed: shipped).render(result, path: "config/flags.manifest.json"))
      .to eq("standard_flags:manifest:check OK: config/flags.manifest.json matches the registry")
  end

  it "reports a missing manifest as stale (exit 1)" do
    result = check(committed: nil, base: shipped).call
    expect([ result.status, result.exit_code ]).to eq([ :missing, 1 ])
    expect(check(committed: nil, base: shipped).render(result, path: "config/flags.manifest.json")).to eq(<<~TEXT.chomp)
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

  describe "the baseline" do
    let(:regenerated) do
      declare do
        kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chatEnabled, web: :assistant }
        experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
        tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
        tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
      end
    end

    it "warns loudly when there is none and the committed file stands in for it" do
      subject = described_class.new(committed: regenerated, today: today)
      result = subject.call

      expect([ result.status, result.warnings ]).to eq([ :ok, [ described_class::NO_BASE_WARNING ] ])
      expect(subject.render(result, path: "config/flags.manifest.json")).to eq(<<~TEXT.chomp)
        standard_flags:manifest:check OK: config/flags.manifest.json matches the registry
        standard_flags:manifest:check: warning: #{described_class::NO_BASE_WARNING}
      TEXT
    end

    it "fails (exit 2) when a given baseline is unavailable, without regenerate advice" do
      [ nil, described_class::Unavailable.new("BASE tmp/base.json does not exist") ].each do |base|
        subject = check(committed: regenerated, base: base)
        result = subject.call

        expect([ result.status, result.exit_code, result.findings ]).to eq([ :baseline_unavailable, 2, [] ])
        expect(subject.render(result)).to eq(
          "standard_flags:manifest:check: the baseline manifest is unavailable (#{base ? base.reason : 'no baseline was given'}). " \
          "The removed-wire and type checks need it; set BASE_OPTIONAL=1 only when the base branch has no manifest yet."
        )
      end
    end

    it "skips the contract checks with a warning when the baseline is optional" do
      result = check(committed: regenerated, base: described_class::Unavailable.new("BASE x does not exist"), base_optional: true).call

      expect([ result.status, result.findings ]).to eq([ :ok, [] ])
      expect(result.warnings).to eq([ "no baseline (BASE x does not exist; BASE_OPTIONAL): the removed-wire and type checks were skipped" ])
    end

    it "still names dropped wires when the committed file is missing" do
      declare do
        experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
        tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
      end
      subject = check(committed: nil, base: shipped)
      result = subject.call

      expect([ result.status, result.exit_code ]).to eq([ :breaking, 2 ])
      expect(result.removed_wires.map(&:to_s).size).to eq(3)
      expect(subject.render(result, path: "config/flags.manifest.json").lines.map(&:chomp)).to include(
        "standard_flags:manifest:check: config/flags.manifest.json does not exist",
        "Run bin/rails standard_flags:manifest and commit the result."
      )
    end
  end

  it "reports an unreadable manifest (exit 2), and which one" do
    subject = check(committed: "{not json", base: shipped)
    result = subject.call

    expect([ result.status, result.exit_code, result.error_source, result.error ]).to match([ :unreadable, 2, :committed, /not valid JSON/ ])
    expect(subject.render(result)).to eq(<<~TEXT.chomp)
      standard_flags:manifest:check: can't read the committed manifest: #{result.error}
      Run bin/rails standard_flags:manifest and commit the result.
    TEXT

    base = check(committed: shipped, base: '{"version":9}')
    result = base.call
    expect([ result.error_source, result.error ]).to eq([ :base, "unknown manifest version 9 (this gem reads 1 and 2)" ])
    expect(base.render(result)).not_to include("Run bin/rails")
  end

  it "treats a public audience made private, while it served wires, as breaking" do
    StandardFlags.config.audiences = { mobile: {}, pre_auth: { public: true } }
    base = declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { pre_auth: :chat }
      tombstone :old, removed: "2026-01-01", serve: { mobile: { old: true } }, until: "2026-06-01"
    end
    StandardFlags.config.audiences = { mobile: {}, pre_auth: {} }
    declare { kill_switch :ai_assistant, owner: "assistant", expose: { pre_auth: :chat } }
    result = check(committed: base).call

    expect([ result.status, result.audiences_made_private.map(&:to_h) ]).to eq([ :breaking, [ { "audience" => "pre_auth" } ] ])
    expect(result.audiences_made_private.first.detail).to start_with("audience made private: pre_auth was public, so clients before sign-in lose its 1 wire;")

    StandardFlags.config.audiences = { mobile: {}, pre_auth: { public: true } }
    empty = declare { kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chat } }
    StandardFlags.config.audiences = { mobile: {}, pre_auth: {} }
    declare { kill_switch :ai_assistant, owner: "assistant", expose: { mobile: :chat } }
    expect(check(committed: empty).call.audiences_made_private).to eq([])
  end

  it "warns, without failing, when a deprecated wire's until moves earlier" do
    declare do
      kill_switch :ai_assistant, owner: "assistant", expose: { mobile: %i[chat chatEnabled], web: :assistant }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-02-01"
      tombstone :banner_v1, removed: "2026-06-01", serve: { web: { banner: true } }, until: "2026-12-31"
    end
    result = check(committed: shipped).call

    expect([ result.status, result.findings ]).to eq([ :stale, [] ])
    expect(result.warnings).to eq([ "tombstone :chat_v1 now serves mobile.chat_v1 through 2027-02-01, earlier than the 2027-03-01 shipped clients were promised" ])
  end

  it "normalises a long run of newlines in linear time" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(check(committed: "#{shipped}#{"\r\n" * 200_000}").call.status).to eq(:ok)
    expect(check(committed: "#{shipped}#{"\n" * 400_000}").call.status).to eq(:ok)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
  end

  it "ignores CRLF line endings and trailing newlines, but not other formatting" do
    expect(check(committed: shipped.gsub("\n", "\r\n")).call.status).to eq(:ok)
    expect(check(committed: "#{shipped}\n\n").call.status).to eq(:ok)
    expect(check(committed: shipped.chomp).call.status).to eq(:ok)
    expect(check(committed: shipped.sub("{\n", "{ \n")).call.status).to eq(:stale)
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
      ENV.delete("BASE_OPTIONAL")
    end

    def run(base: nil, optional: false)
      ENV["BASE"] = base if base
      ENV["BASE_OPTIONAL"] = "1" if optional
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

    it "exits 0 when the committed manifest is current, warning when no BASE was given" do
      write_manifest
      expect { expect(run).to eq(0) }
        .to output(%r{OK: config/flags.manifest.json matches the registry\n.*warning: no BASE was given}).to_stdout
      FileUtils.cp(root.join("config/flags.manifest.json"), root.join("base.json"))
      expect { expect(run(base: root.join("base.json").to_s)).to eq(0) }.not_to output(/warning/).to_stdout
    end

    it "exits 1 when the committed manifest is stale" do
      write_manifest
      File.write(root.join("config/flags.manifest.json"), "#{shipped} ")
      expect { expect(run).to eq(1) }.to output(/is stale/).to_stderr
    end

    it "exits 2 on a wire BASE told a client that is gone" do
      write_manifest
      File.write(root.join("base.json"), shipped.sub('"chatEnabled"', %("chatEnabled",\n          "legacyChat")))
      expect { expect(run(base: root.join("base.json").to_s)).to eq(2) }.to output(/removed wire: mobile.legacyChat/).to_stderr
    end

    it "exits 2 when BASE is missing or a directory" do
      write_manifest
      missing = root.join("missing.json").to_s
      expect { expect(run(base: missing)).to eq(2) }.to output(/baseline manifest is unavailable \(BASE #{missing} does not exist\)/).to_stderr
      expect { expect(run(base: root.to_s)).to eq(2) }.to output(/BASE #{root} is a directory/).to_stderr
    end

    it "skips the contract checks, with a warning, when BASE is missing and BASE_OPTIONAL=1" do
      write_manifest
      missing = root.join("missing.json").to_s
      expect { expect(run(base: missing, optional: true)).to eq(0) }
        .to output(/OK.*\n.*warning: no baseline \(BASE #{missing} does not exist; BASE_OPTIONAL\)/).to_stdout
    end

    it "writes the Kotlin file" do
      expect { RakeTasks.invoke("standard_flags:kotlin") }.to output(%r{Wrote config/StandardFlags.kt}).to_stdout
      expect(root.join("config/StandardFlags.kt").read).to include("enum class MobileFeature(")
    end
  end
end
