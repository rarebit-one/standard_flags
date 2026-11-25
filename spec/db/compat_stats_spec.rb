require "spec_helper"

RSpec.describe "compat stats on Postgres", :db, registry: RuntimeHelpers::COMPAT do
  let(:models) { StandardFlags::Runtime::Models }
  let(:store) { StandardFlags::Runtime.store }
  let(:time) { [ 0.0 ] }
  let(:at) { Time.utc(2026, 12, 1, 12) }

  before do
    require "standard_flags/runtime/active_record_store"
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.track_compat = true
    StandardFlags::Runtime.clock = -> { time.first }
  end

  def stat(platform, hits, version, last_hit_at, key: :legacy_auth)
    StandardFlags::Runtime::CompatStat.new(key: key, platform: platform, hits: hits, oldest_version: version, last_hit_at: last_hit_at)
  end

  it "upserts: hits add up, the latest hit and the oldest version (by SemVer, not text) win" do
    expect(store.record_compat([ stat("android", 2, "0.1.10", at), stat("ios", 1, nil, at) ])).to eq(2)
    expect(store.record_compat([ stat("android", 3, "0.1.9", at - 60), stat("ios", 1, "2.0.0", at + 60) ])).to eq(2)
    expect(store.record_compat([ stat("android", 1, "0.1.11", at + 120) ])).to eq(1)
    expect(store.compat_stats.map(&:to_h)).to eq([
      { key: "legacy_auth", platform: "android", hits: 6, oldest_version: "0.1.9", last_hit_at: "2026-12-01T12:02:00Z" },
      { key: "legacy_auth", platform: "ios", hits: 2, oldest_version: "2.0.0", last_hit_at: "2026-12-01T12:01:00Z" }
    ])
  end

  it "reads stats for given keys only, and writes nothing for no stats" do
    store.record_compat([ stat("android", 1, "0.1.0", at) ])
    expect(store.compat_stats([ "old_export" ])).to eq([])
    expect(store.record_compat([])).to eq(0)
  end

  it "keeps a prerelease below its release" do
    store.record_compat([ stat("android", 1, "1.0.0", at) ])
    store.record_compat([ stat("android", 1, "1.0.0-rc.1", at) ])
    store.record_compat([ stat("android", 1, "1.0.0-beta", at) ])
    expect(store.compat_stats.first.oldest_version).to eq("1.0.0-beta")
  end

  it "skips the write inside an open transaction, keeping the counts for later" do
    ActiveRecord::Base.transaction do
      expect(store.record_compat([ stat("android", 1, "0.1.0", at) ])).to be_nil
    end
    expect(models::CompatStat.count).to eq(0)
  end

  def without_compat_table
    ActiveRecord::Base.connection.rename_table(:standard_flags_compat_stats, :standard_flags_compat_stats_away)
    models::CompatStat.reset_column_information
    yield
  ensure
    ActiveRecord::Base.connection.rename_table(:standard_flags_compat_stats_away, :standard_flags_compat_stats)
    models::CompatStat.reset_column_information
  end

  it "says the table is missing, and how to add it, when the migration hasn't run" do
    without_compat_table do
      expect { store.record_compat([ stat("android", 1, "0.1.0", at) ]) }.to raise_error(
        an_instance_of(StandardFlags::Runtime::StoreError)
          .and(having_attributes(message: "compat tracking failed: standard_flags_compat_stats is missing; run bin/rails g " \
                                          "standard_flags:migrations and migrate", cause_class: "StandardFlags::MissingCompatTable"))
      )
      expect { store.compat_stats }.to raise_error(StandardFlags::Runtime::StoreError, /compat stats failed/)
      expect(StandardFlags::Runtime.store).to be_ready
    end
  end

  it "tries at most once per interval while the table is missing" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("compat_tracking_failed.standard_flags") { |*, payload| events << payload }
    StandardFlags.config.evaluation_tracking_interval = 3600
    without_compat_table do
      10.times do
        Rails.application.executor.wrap do
          StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: { platform: "android", version: "0.1.0" }))
        end
        time[0] += 1
      end
    end
    expect(events).to eq([ { error_class: "StandardFlags::MissingCompatTable" } ])
    expect(StandardFlags::Runtime.compat_tracker.pending.first.hits).to eq(10)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "keeps first_seen_at, and lets the oldest version start over after 14 idle days" do
    store.record_compat([ stat("android", 1, "0.0.0", at) ])
    first = models::CompatStat.pick(:first_seen_at)
    store.record_compat([ stat("android", 1, "0.1.5", at + (13 * 86_400)) ])
    expect(store.compat_stats.first.oldest_version).to eq("0.0.0")
    store.record_compat([ stat("android", 1, "0.2.0", at + (28 * 86_400)) ])
    expect(store.compat_stats.first).to have_attributes(oldest_version: "0.2.0", hits: 3, first_seen_at: first)
  end

  it "counts evaluations end to end, through the executor hook" do
    StandardFlags.config.evaluation_tracking_interval = 60
    Rails.application.executor.wrap do
      StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: { platform: "android", version: "0.1.3" }))
      StandardFlags.evaluate(:legacy_auth, for: StandardFlags::Context.new(client: { platform: "android", version: "0.1.1" }))
    end
    expect(store.compat_stats.map { |row| [ row.platform, row.hits, row.oldest_version ] })
      .to eq([ [ "*", 0, nil ], [ "android", 2, "0.1.1" ] ])
  end

  # Another process lowers the row to `version` after this one's first read.
  def lowered_after_first_read(row, version)
    reads = 0
    allow(models::CompatStat).to receive(:where).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap do |relation|
        allow(relation).to receive(:pick).and_wrap_original do |pick, *columns|
          pick.call(*columns).tap { row.update_all(oldest_version: version) if (reads += 1) == 1 }
        end
      end
    end
    yield
    reads
  end

  it "lowers the oldest version past a concurrent change" do
    store.record_compat([ stat("android", 1, "0.5.0", at) ])
    row = models::CompatStat.where(key: "legacy_auth", platform: "android")
    reads = lowered_after_first_read(row, "0.4.0") { store.record_compat([ stat("android", 1, "0.3.0", at) ]) }
    expect(reads).to eq(2)
    expect(row.pick(:oldest_version)).to eq("0.3.0")
  end
end
