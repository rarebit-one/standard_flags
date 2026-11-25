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

    def counts
      store.compat_stats.reject(&:marker?)
    end

    it "writes when a unit of work ends, at most once per interval, adding up across writes" do
      run_for(30)
      expect(store.reads[:record_compat]).to eq(1)
      expect(counts.map(&:to_h)).to eq([ { key: "legacy_auth", platform: "android", hits: 1, oldest_version: "0.1.10",
                                           last_hit_at: counts.first.last_hit_at.utc.iso8601 } ])
      run_for(60, version: "0.1.2")
      expect(store.reads[:record_compat]).to eq(2)
      expect([ counts.first.hits, counts.first.oldest_version ]).to eq([ 61, "0.1.2" ])
    end

    it "refreshes each window's tracking marker on every successful write, once per interval, even without hits" do
      unit_of_work { StandardFlags.evaluate(:new_checkout) }
      marker = store.compat_stats.find(&:marker?)
      expect([ marker.key, marker.platform, marker.hits ]).to eq([ "legacy_auth", "*", 0 ])
      expect([ marker.first_seen_at, marker.last_flushed_at ]).to all(be_within(5).of(Time.now.utc))
      time[0] += 30
      unit_of_work { StandardFlags.evaluate(:new_checkout) }
      expect(store.reads[:record_compat]).to eq(1)
      later = Time.now.utc + 3600
      allow(Time).to receive(:now).and_return(later)
      time[0] += 60
      unit_of_work { StandardFlags.evaluate(:new_checkout) }
      refreshed = store.compat_stats.find(&:marker?)
      expect(store.reads[:record_compat]).to eq(2)
      expect([ refreshed.first_seen_at, refreshed.last_flushed_at ]).to eq([ marker.first_seen_at, later ])
    end

    it "reads the stored stats back by flag key" do
      run_for(1)
      expect(StandardFlags::Runtime.compat_stats([ :legacy_auth ]).reject(&:marker?).size).to eq(1)
      expect(StandardFlags::Runtime.compat_stats([ :old_export ])).to eq([])
    end

    it "tries a failing write at most once per interval, with one event per interval, keeping the counts" do
      StandardFlags.config.evaluation_tracking_interval = 3600
      reports = []
      events = []
      StandardFlags.config.error_reporter = ->(error, context) { reports << [ error.class.name, context ] }
      subscriber = ActiveSupport::Notifications.subscribe("compat_tracking_failed.standard_flags") { |*, payload| events << payload }
      allow(store).to receive(:record_compat).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::UndefinedTable"))
      run_for(60)
      expect(store).to have_received(:record_compat).once
      expect(events).to eq([ { error_class: "PG::UndefinedTable" } ])
      expect(reports).to eq([ [ "StandardFlags::Runtime::StoreError", { runtime: "compat_tracking" } ] ])
      expect(StandardFlags::Runtime.compat_tracker.pending.first.hits).to eq(60)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "writes everything kept once the store recovers, and only then records the marker" do
      allow(store).to receive(:record_compat).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::ConnectionBad"))
      run_for(3)
      allow(store).to receive(:record_compat).and_call_original
      expect(store.compat_stats).to eq([])
      time[0] += 60
      run_for(1, version: "0.1.0")
      expect(counts.first).to have_attributes(hits: 4, oldest_version: "0.1.0")
      expect(store.compat_stats.count(&:marker?)).to eq(1)
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
    end

    it "tries again at the next unit of work when the store skipped the write" do
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

    it "drops pending counts in a forked child; the parent writes them" do
      evaluate_as("android", "0.1.0")
      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      expect(StandardFlags::Runtime.compat_tracker.pending).to eq([])
    end
  end

  describe "MemoryStore" do
    def stat(hits, version, time, first_seen_at: nil)
      StandardFlags::Runtime::CompatStat.new(key: :k, platform: "android", hits: hits, oldest_version: version, last_hit_at: time,
                                             first_seen_at: first_seen_at)
    end

    it "adds hits, keeps the oldest version, the latest hit and the first first_seen_at" do
      at = Time.utc(2026, 12, 1)
      store.record_compat([ stat(2, "1.2.0", at, first_seen_at: at - 86_400) ])
      store.record_compat([ stat(3, "1.10.0", at - 60) ])
      store.record_compat([ stat(1, nil, at + 60) ])
      expect(store.compat_stats([ "k" ]).map(&:to_h))
        .to eq([ { key: "k", platform: "android", hits: 6, oldest_version: "1.2.0", last_hit_at: "2026-12-01T00:01:00Z" } ])
      store.record_compat([ stat(1, "1.1.0-beta", nil) ])
      expect(store.compat_stats.first).to have_attributes(hits: 7, oldest_version: "1.1.0-beta", last_hit_at: at + 60,
                                                          first_seen_at: at - 86_400)
    end

    it "lets the oldest version start over after the row went unused for 14 days" do
      at = Time.utc(2026, 12, 1)
      store.record_compat([ stat(1, "0.0.0", at) ])
      store.record_compat([ stat(1, "0.1.5", at + (13 * 86_400)) ])
      expect(store.compat_stats.first.oldest_version).to eq("0.0.0")
      store.record_compat([ stat(1, "0.2.0", at + (28 * 86_400)) ])
      expect(store.compat_stats.first.oldest_version).to eq("0.2.0")
    end
  end

  describe "the oldest version" do
    it "comes only from clients on an allowlisted platform; others still count as hits" do
      track!
      unit_of_work do
        StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: { platform: "palm", version: "0.0.0" }))
        StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: StandardFlags::Client.from_headers(
          "X-Client-Platform" => "watch", "X-Client-Version" => "0.0.1"
        )))
      end
      expect(store.compat_stats.reject(&:marker?).map { |row| [ row.platform, row.hits, row.oldest_version ] })
        .to eq([ [ "unknown", 2, nil ] ])
    end
  end

  describe "diagnostics and MCP" do
    it "lists compat windows with their stored counts and when tracking began" do
      track!
      unit_of_work { evaluate_as("android", "0.1.4") }
      report = StandardFlags::Diagnostics.report
      expect(report[:compat]).to match(tracking: true, error: nil, flags: [
        { flag: :legacy_auth, until_clients: { "android" => "0.1.12", "ios" => "2.0.0" }, tracking_since: a_string_matching(/\A\d{4}-/),
          last_flushed_at: a_string_matching(/\A\d{4}-/),
          stats: [ a_hash_including(key: "legacy_auth", platform: "android", hits: 1, oldest_version: "0.1.4") ] }
      ])
      expect(StandardFlags::Diagnostics.warnings(report)).to eq([])
    end

    it "warns when tracking is on without runtime rules, or the stats can't be read" do
      StandardFlags.config.track_compat = true
      report = StandardFlags::Diagnostics.report
      expect(report[:compat]).to eq(tracking: false, error: nil, flags: [
        { flag: :legacy_auth, until_clients: { "android" => "0.1.12", "ios" => "2.0.0" }, tracking_since: nil, last_flushed_at: nil,
          stats: nil }
      ])
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
                                        "tracking_since" => a_string_matching(/\A\d{4}-/),
                                        "last_flushed_at" => a_string_matching(/\A\d{4}-/),
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

    # Tracking began `days` ago.
    # Tracking began `days` ago, and a write last succeeded `flushed` days ago.
    def tracked_for(days, target = store, flushed: 0)
      target.record_compat([ StandardFlags::Runtime::CompatStat.new(key: :legacy_auth, platform: "*", hits: 0, oldest_version: nil,
                                                                    last_hit_at: now - (flushed * 86_400),
                                                                    first_seen_at: now - (days * 86_400)) ])
    end

    before { track! }

    it "says tracking is unhealthy, not removable, when no write has succeeded for 2 days" do
      tracked_for(30, flushed: 3)
      expect(stale).to include("compat legacy_auth: tracking unhealthy since 2026-12-17 (no successful write since); " \
                               "not enough data to judge its window")
      expect(stale).not_to include("can be removed")
    end

    it "trusts a write within 2 days" do
      tracked_for(30, flushed: 2)
      expect(stale).to include("can be removed")
    end

    it "never advises removal while writes fail after the marker was first written" do
      StandardFlags::Runtime.clock = -> { time.first }
      StandardFlags.config.evaluation_tracking_interval = 3600
      first = now - (25 * 86_400)
      allow(Time).to receive(:now).and_return(first)
      unit_of_work { StandardFlags.evaluate(:new_checkout) }
      allow(store).to receive(:record_compat).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::InsufficientPrivilege"))
      20.times do |day|
        allow(Time).to receive(:now).and_return(first + ((day + 1) * 86_400))
        time[0] += 86_400
        unit_of_work { evaluate_as("android", "0.1.0") }
      end
      allow(store).to receive(:compat_stats).and_call_original
      expect(stale).to include("compat legacy_auth: tracking unhealthy since 2026-11-25")
      expect(stale).not_to include("can be removed")
    end


    def android_clients(android_since)
      proc do
        client :android_app, platform: :android, min_version: "0.1.12", since: android_since
        client :kiosk_android, platform: :android, group: :kiosk, min_version: "0.2.0", since: "2026-11-01"
        compat :legacy_auth, owner: "identity", until_clients: { android: "0.1.12" }
      end
    end

    it "says there isn't enough data on the day tracking is switched on" do
      expect(stale).to include("compat legacy_auth: not enough data to judge its window (no tracking recorded yet; needs 14 days)")
      expect(stale).not_to include("can be removed")
    end

    it "says there isn't enough data until tracking is 14 days old" do
      tracked_for(13)
      expect(stale).to include("compat legacy_auth: not enough data to judge its window (tracking since 2026-12-07; needs 14 days)")
    end

    it "reports a window passed on every platform with no hits for 14 days, once tracking is old enough" do
      tracked_for(30)
      store.record_compat([ stat("android", "0.1.12", now - (15 * 86_400)), stat("ios", "2.1.0", now - (20 * 86_400)) ])
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform " \
                               "(android 0.1.12, ios 2.0.0) and has had no hits since 2026-12-05; it can be removed")
    end

    it "reports a window that was never hit once tracking has run for 14 days" do
      tracked_for(14)
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform (android 0.1.12, ios 2.0.0) " \
                               "and has had no hits since tracking began on 2026-12-06; it can be removed")
    end

    it "keeps quiet while it has been hit in the last 14 days" do
      tracked_for(30)
      store.record_compat([ stat("android", "0.2.0", now - (13 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
    end

    it "keeps quiet while a platform's oldest client is inside the window, or its versions were unknown" do
      tracked_for(60)
      store.record_compat([ stat("android", "0.1.11", now - (30 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
      fresh = StandardFlags::Runtime::MemoryStore.new
      StandardFlags.config.runtime_store = fresh
      tracked_for(60, fresh)
      fresh.record_compat([ stat("ios", nil, now - (30 * 86_400)) ])
      expect(stale).not_to include("compat legacy_auth")
    end

    it "counts a platform as past its window once every client declared for it enforces the version (UTC)" do
      tracked_for(60)
      store.record_compat([ stat("android", "0.1.0", now - (30 * 86_400)) ])
      clients = method(:android_clients)
      StandardFlags.define(&clients.call("2026-12-01"))
      expect(stale).to include("compat legacy_auth (owner: identity) is past its window on every platform (android 0.1.12)")
      StandardFlags.define(&clients.call("2026-12-14"))
      expect(stale).not_to include("compat legacy_auth")
      StandardFlags.define(&clients.call("2026-12-01"))
      StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_AVAILABLE" => "0.1.11" }
      expect(stale).not_to include("compat legacy_auth")
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
