require "spec_helper"

RSpec.describe StandardFlags::Runtime::CompatTracker, registry: RuntimeHelpers::COMPAT do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:time) { [ 0.0 ] }

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  def evaluate_as(platform, version = nil)
    StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: { platform: platform, version: version }.compact))
  end

  def track!
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    StandardFlags.config.track_compat = true
    StandardFlags::Runtime.clock = -> { time.first }
  end

  describe "until_clients:" do
    it "declares a compat flag's window, per platform" do
      definition = StandardFlags.registry[:legacy_auth]
      expect(definition.until_clients).to eq("android" => StandardFlags::Version.parse("0.1.12"),
                                             "ios" => StandardFlags::Version.parse("2.0.0"))
      expect(definition).to be_compat_window
      expect(StandardFlags.registry[:old_export]).not_to be_compat_window
      expect(StandardFlags.registry[:old_export].until_clients).to eq({})
    end

    it "is only for compat flags, and is validated" do
      expect { StandardFlags.define { flag :x, owner: "o", permanent: true, until_clients: { android: "1.0.0" } } }
        .to raise_error(StandardFlags::DefinitionError, /unknown attribute\(s\): :until_clients/)
      {
        [] => "until_clients: must be a Hash of platform => version",
        {} => "until_clients: must name at least one platform",
        { watch: "1.0.0" } => "until_clients: platform :watch is not one of config.client_platforms",
        { android: "next" } => "until_clients: \"next\" for android is not a version"
      }.each do |value, message|
        expect { StandardFlags.define { compat :x, owner: "o", until_clients: value } }
          .to raise_error(StandardFlags::DefinitionError, /compat :x #{Regexp.escape(message)}/)
      end
    end
  end

  describe "hit counting" do
    it "is off by default, and needs runtime rules" do
      evaluate_as("android", "0.1.0")
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
      StandardFlags.config.track_compat = true
      evaluate_as("android", "0.1.0")
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
    end

    it "counts every evaluation and the oldest version per platform" do
      track!
      unit_of_work do
        evaluate_as("android", "0.1.11")
        evaluate_as("android", "0.1.11")
        evaluate_as("android", "0.1.9")
        evaluate_as("android", "0.2.0")
        evaluate_as("ios")
        evaluate_as("palm", "1.0.0")
        StandardFlags.evaluate(:legacy_auth)
        StandardFlags.evaluate(:old_export)
        StandardFlags.evaluate(:new_checkout)
        pending = StandardFlags::Runtime.compat_tracker.pending
        expect(pending.map { |stat| [ stat.key, stat.platform, stat.hits, stat.oldest_version ] })
          .to eq([ [ :legacy_auth, "android", 4, "0.1.9" ], [ :legacy_auth, "ios", 1, nil ], [ :legacy_auth, "none", 1, nil ],
                   [ :legacy_auth, "unknown", 1, nil ] ])
        expect(pending.first.last_hit_at).to be_within(5).of(Time.now.utc)
      end
    end

    it "doesn't count operator reads: MCP tools, diagnostics, or an untracked block" do
      track!
      StandardFlags.config.authorize = ->(*) { true }
      StandardFlags::MCP.tool("get_flag").call({ "key" => "legacy_auth" }, actor: StandardFlags::Actor.system("spec"))
      StandardFlags::MCP.tool("list_flags").call({}, actor: StandardFlags::Actor.system("spec"))
      StandardFlags::Diagnostics.report
      described_class.untracked { evaluate_as("android", "0.1.0") }
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
      evaluate_as("android", "0.1.0")
      expect(StandardFlags::Runtime.compat_tracker.pending.size).to eq(1)
    end

    it "never lets a failure reach the read" do
      track!
      allow(StandardFlags::Runtime.compat_tracker).to receive(:hit).and_raise(RuntimeError)
      expect(evaluate_as("android", "0.1.0").value).to be(true)
    end
  end

  describe "the write-behind" do
    before do
      track!
      StandardFlags.config.evaluation_tracking_interval = 60
    end

    def run_for(seconds, version: "0.1.10")
      seconds.times do
        unit_of_work { evaluate_as("android", version) }
        time[0] += 1
      end
    end

    it "writes when a unit of work ends, at most once per interval, adding up across writes" do
      run_for(30)
      expect(store.reads[:record_compat]).to eq(1)
      expect(store.compat_stats.map(&:to_h)).to eq([ { key: "legacy_auth", platform: "android", hits: 1, oldest_version: "0.1.10",
                                                        last_hit_at: store.compat_stats.first.last_hit_at.utc.iso8601 } ])
      run_for(60, version: "0.1.2")
      expect(store.reads[:record_compat]).to eq(2)
      stat = store.compat_stats.first
      expect([ stat.hits, stat.oldest_version ]).to eq([ 61, "0.1.2" ])
    end

    it "reads the stored stats back by flag key" do
      run_for(1)
      expect(StandardFlags::Runtime.compat_stats([ :legacy_auth ]).size).to eq(1)
      expect(StandardFlags::Runtime.compat_stats([ :old_export ])).to eq([])
    end

    it "keeps the counts and reports once when a write fails, then writes them all" do
      reports = []
      StandardFlags.config.error_reporter = ->(error, context) { reports << [ error.class.name, context ] }
      allow(store).to receive(:record_compat).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::UndefinedTable"))
      run_for(3)
      run_for(1)
      expect(reports).to eq([ [ "StandardFlags::Runtime::StoreError", { runtime: "compat_tracking" } ] ])
      expect(StandardFlags::Runtime.compat_tracker.pending.first.hits).to eq(4)
      allow(store).to receive(:record_compat).and_call_original
      run_for(1, version: "0.1.0")
      expect(store.compat_stats.first).to have_attributes(hits: 5, oldest_version: "0.1.0")
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
    end

    it "keeps the counts when the store doesn't keep compat stats" do
      StandardFlags.config.runtime_store = RuntimeHelpers::RawStore.new
      run_for(2)
      expect(StandardFlags::Runtime.compat_tracker.pending.first.hits).to eq(2)
      expect(StandardFlags::Runtime.compat_stats).to be_nil
    end

    it "writes nothing when tracking is turned off" do
      run_for(1)
      StandardFlags.config.track_compat = false
      time[0] += 120
      run_for(1)
      expect(store.reads[:record_compat]).to eq(1)
    end
  end

  describe "MemoryStore" do
    it "adds hits, keeps the oldest version and the latest hit" do
      at = Time.utc(2026, 12, 1)
      stat = ->(hits, version, time) { StandardFlags::Runtime::CompatStat.new(key: :k, platform: "android", hits: hits, oldest_version: version, last_hit_at: time) }
      store.record_compat([ stat.call(2, "1.2.0", at) ])
      store.record_compat([ stat.call(3, "1.10.0", at - 60) ])
      store.record_compat([ stat.call(1, nil, at + 60) ])
      expect(store.compat_stats([ "k" ]).map(&:to_h))
        .to eq([ { key: "k", platform: "android", hits: 6, oldest_version: "1.2.0", last_hit_at: "2026-12-01T00:01:00Z" } ])
      store.record_compat([ stat.call(1, "1.1.0-beta", nil) ])
      expect(store.compat_stats.first).to have_attributes(hits: 7, oldest_version: "1.1.0-beta", last_hit_at: at + 60)
    end
  end

  describe "diagnostics and MCP" do
    it "lists compat windows with their stored counts" do
      track!
      unit_of_work { evaluate_as("android", "0.1.4") }
      report = StandardFlags::Diagnostics.report
      expect(report[:compat]).to match(tracking: true, error: nil, flags: [
        { flag: :legacy_auth, until_clients: { "android" => "0.1.12", "ios" => "2.0.0" },
          stats: [ a_hash_including(key: "legacy_auth", platform: "android", hits: 1, oldest_version: "0.1.4") ] }
      ])
      expect(StandardFlags::Diagnostics.warnings(report)).to eq([])
    end

    it "warns when tracking is on without runtime rules, or the stats can't be read" do
      StandardFlags.config.track_compat = true
      report = StandardFlags::Diagnostics.report
      expect(report[:compat]).to eq(tracking: false, error: nil, flags: [ { flag: :legacy_auth, until_clients: { "android" => "0.1.12", "ios" => "2.0.0" }, stats: nil } ])
      expect(StandardFlags::Diagnostics.warnings(report)).to eq([ "config.track_compat is on but runtime rules are off, so compat hits are not counted" ])
      expect(report[:status]).to eq(:warn)
      track!
      allow(store).to receive(:compat_stats).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::UndefinedTable"))
      report = StandardFlags::Diagnostics.report
      expect(report[:compat][:error]).to eq("PG::UndefinedTable")
      expect(StandardFlags::Diagnostics.warnings(report)).to include("compat stats could not be read (PG::UndefinedTable)")
    end

    it "leaves the report unchanged without compat windows or clients" do
      StandardFlags.define { flag :new_checkout, owner: "payments", remove_by: "2099-01-01", final: true }
      expect(StandardFlags::Diagnostics.report.keys).not_to include(:compat, :clients)
    end

    it "shows the window and counts in get_flag, and nothing extra for other flags" do
      track!
      unit_of_work { evaluate_as("ios", "1.9.0") }
      StandardFlags.config.authorize = ->(*) { true }
      tool = StandardFlags::MCP.tool("get_flag")
      result = tool.call({ "key" => "legacy_auth" }, actor: StandardFlags::Actor.system("spec"))
      expect(result["compat"]).to match("until_clients" => { "android" => "0.1.12", "ios" => "2.0.0" }, "tracking" => true, "error" => nil,
                                        "stats" => [ a_hash_including("platform" => "ios", "hits" => 1, "oldest_version" => "1.9.0") ])
      expect(tool.call({ "key" => "old_export" }, actor: StandardFlags::Actor.system("spec"))).not_to have_key("compat")
    end
  end

  describe "flags:stale" do
    let(:now) { Time.utc(2026, 12, 20) }

    def stale(today: now.to_date)
      StandardFlags::Tooling::Stale.new(today: today, now: now).render
    end

    def stat(platform, version, last_hit_at, hits: 3)
      StandardFlags::Runtime::CompatStat.new(key: :legacy_auth, platform: platform, hits: hits, oldest_version: version, last_hit_at: last_hit_at)
    end

    before { track! }

    it "reports a window passed on every platform with no hits for 14 days" do
      store.record_compat([ stat("android", "0.1.12", now - (15 * 86_400)), stat("ios", "2.1.0", now - (20 * 86_400)) ])
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform " \
                               "(android 0.1.12, ios 2.0.0) and has had no hits since 2026-12-05; it can be removed")
    end

    it "keeps quiet while it has been hit in the last 14 days" do
      store.record_compat([ stat("android", "0.2.0", now - (13 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
    end

    it "keeps quiet while a platform's oldest client is inside the window, or its versions were unknown" do
      store.record_compat([ stat("android", "0.1.11", now - (30 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
      store.record_compat([ stat("android", "0.1.12", now - (30 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
      fresh = StandardFlags::Runtime::MemoryStore.new
      StandardFlags.config.runtime_store = fresh
      fresh.record_compat([ stat("ios", nil, now - (30 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
    end

    it "counts a platform as past its window once every client declared for it enforces the version" do
      store.record_compat([ stat("android", "0.1.0", now - (30 * 86_400)) ])
      clients = proc do |android_since|
        proc do
          client :android_app, platform: :android, min_version: "0.1.12", since: android_since
          client :kiosk_android, platform: :android, group: :kiosk, min_version: "0.2.0", since: "2026-11-01"
          compat :legacy_auth, owner: "identity", until_clients: { android: "0.1.12" }
        end
      end
      StandardFlags.define(&clients.call("2026-12-01"))
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform (android 0.1.12)")
      StandardFlags.define(&clients.call("2026-12-14"))
      expect(stale).not_to include("compat legacy_auth")
      StandardFlags.define(&clients.call("2026-12-01"))
      StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_AVAILABLE" => "0.1.11" }
      expect(stale).not_to include("compat legacy_auth")
    end

    it "reports a window with no hits recorded at all" do
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform (android 0.1.12, ios 2.0.0) " \
                               "and has had no hits recorded; it can be removed")
    end

    it "says nothing about compat windows unless tracking is on" do
      StandardFlags.config.track_compat = false
      expect(stale).not_to include("compat")
    end

    it "says when the stats can't be read, or the store keeps none" do
      allow(store).to receive(:compat_stats).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::UndefinedTable"))
      expect(stale).to include("compat windows: could not read the stats (PG::UndefinedTable)")
      StandardFlags.config.runtime_store = RuntimeHelpers::RawStore.new
      expect(stale).to include("compat windows: the runtime store doesn't keep compat stats")
    end
  end
end
