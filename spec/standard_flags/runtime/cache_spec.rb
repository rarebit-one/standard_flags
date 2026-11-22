require "spec_helper"

RSpec.describe StandardFlags::Runtime::Cache, registry: RuntimeHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:time) { [ 100.0 ] }
  let(:cache) { described_class.new(store, clock: -> { time.first }) }

  # A store whose revision check fails while `broken`.
  let(:failing) do
    Class.new(StandardFlags::Runtime::MemoryStore) do
      attr_accessor :broken

      def revision
        raise StandardFlags::Runtime::StoreError.new("revision check failed", cause_class: "PG::ConnectionBad") if broken

        super
      end
    end.new
  end

  before { store.put_rule(:new_checkout, status: :running, fallthrough_value: true) }

  def advance(seconds)
    time[0] += seconds
  end

  it "loads on first use, then serves the snapshot until the interval passes" do
    first = cache.snapshot
    expect(first).to have_attributes(loaded: true, stale: false, revision: 1)
    expect(first.rule(:new_checkout).fallthrough_value).to eq("on")
    advance(4.9)
    expect(cache.snapshot).to equal(first)
    expect(store.reads).to eq(revision: 1, load: 1)
  end

  it "checks the revision once per interval and reloads only when it moved" do
    cache.snapshot
    advance(5)
    cache.snapshot
    cache.snapshot
    expect(store.reads).to eq(revision: 2, load: 1)

    store.put_rule(:new_checkout, status: :paused)
    advance(5)
    expect(cache.snapshot).to have_attributes(revision: 2)
    expect(cache.snapshot.rule(:new_checkout)).to be_paused
    expect(store.reads).to eq(revision: 3, load: 2)
  end

  it "follows config.refresh_interval" do
    StandardFlags.config.refresh_interval = 60
    cache.snapshot
    advance(30)
    cache.snapshot
    expect(store.reads[:revision]).to eq(1)
  end

  describe "when the store fails after a load" do
    let(:cache) { described_class.new(failing, clock: -> { time.first }) }
    let!(:good) do
      failing.put_rule(:new_checkout, status: :running, fallthrough_value: true)
      cache.snapshot.tap { failing.broken = true }
    end

    def three_failed_intervals
      3.times do
        advance(5)
        2.times { cache.snapshot }
      end
    end

    it "serves the last good snapshot, marked stale" do
      advance(5)
      expect(cache.snapshot).to have_attributes(stale: true, loaded: true, revision: good.revision, rules: good.rules)
    end

    it "reports once and emits runtime_stale once per interval" do
      events = nil
      errors = collect_errors { events = capture_events(/runtime_stale/) { three_failed_intervals } }
      expect(errors.errors_of(StandardFlags::Runtime::StoreError).size).to eq(1)
      expect(events.size).to eq(3)
      expect(events.first.last).to include(error_class: "PG::ConnectionBad", loaded: true, revision: 1)
    end

    it "recovers when the store does" do
      advance(5)
      cache.snapshot
      failing.broken = false
      advance(5)
      expect(cache.snapshot).to have_attributes(stale: false, loaded: true)
    end
  end

  it "serves an unloaded snapshot when the store has never answered" do
    cache = described_class.new(failing, clock: -> { time.first })
    failing.broken = true
    expect(cache.snapshot).to have_attributes(loaded: false, stale: true, revision: nil, age: nil)
  end

  it "returns the current snapshot while another thread holds the refresh" do
    first = cache.snapshot
    advance(5)
    cache.instance_variable_get(:@mutex).synchronize { expect(cache.snapshot).to equal(first) }
    expect(store.reads[:revision]).to eq(1)
  end

  it "takes a fresh lock after a fork and keeps the inherited snapshot" do
    first = cache.snapshot
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    expect(cache.snapshot).to equal(first)
    expect(cache.peek).to equal(first)
  end

  it "reports the snapshot's age" do
    snapshot = cache.snapshot
    expect(snapshot.age(snapshot.loaded_at + 12.5)).to eq(12.5)
  end

  describe "through StandardFlags" do
    before do
      StandardFlags.config.runtime_rules = true
      StandardFlags.config.runtime_store = failing
      StandardFlags::Runtime.clock = -> { time.first }
    end

    it "falls back to code defaults when rules never loaded" do
      failing.broken = true
      expect(StandardFlags.evaluate(:new_checkout, for: for_account(1))).to have_attributes(value: false, reason: "DEFAULT")
    end

    it "keeps serving stored rules while the store is down" do
      failing.put_rule(:new_checkout, status: :running, fallthrough_value: true)
      expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
      failing.broken = true
      advance(5)
      expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
    end
  end
end
