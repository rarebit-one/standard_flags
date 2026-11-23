require "spec_helper"
require "standard_health/check"

RSpec.describe "runtime rules in diagnostics", registry: RuntimeHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:broken) do
    Class.new(StandardFlags::Runtime::MemoryStore) do
      attr_accessor :ready, :fail_reads

      def ready? = ready.nil? || ready

      def revision
        raise StandardFlags::Runtime::StoreError.new("revision check failed", cause_class: "PG::UndefinedTable") if fail_reads

        super
      end
    end.new
  end

  def enable(with)
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = with
  end

  it "leaves the report unchanged with runtime rules off" do
    report = StandardFlags::Diagnostics.report
    expect(report).not_to have_key(:runtime)
    expect(report[:flags].first).not_to have_key(:rule_status)
  end

  it "adds the snapshot and each rule's status" do
    enable(store)
    store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
    report = StandardFlags::Diagnostics.report
    expect(report[:runtime]).to include(enabled: true, ready: true, unreachable: nil, warnings: [], loaded: true, stale: false, revision: 1,
                                        store: "StandardFlags::Runtime::MemoryStore")
    expect(report[:runtime][:rules]).to eq([ { key: :new_checkout, status: "running", percentage_bps: 500,
                                               member_count: 0, cohorts: [], orphan: nil } ])
    expect(report[:flags].find { |row| row[:key] == :new_checkout }[:rule_status]).to eq("running")
    expect(report[:status]).to eq(:ok)
  end

  it "warns on rules for undeclared or tombstoned keys" do
    define_flags do
      tombstone :old_banner, removed: "2026-01-01"
      flag :kept, owner: "web", remove_by: "2099-01-01", final: true
    end
    enable(store)
    store.put_rule(:old_banner, status: :stopped, stop_value: "off")
    store.put_rule(:mystery, status: :draft)
    expect(StandardFlags::Diagnostics.warnings(StandardFlags::Diagnostics.report)).to eq([
      "runtime rule for :mystery has no declared flag (undeclared)",
      "runtime rule for :old_banner has no declared flag (tombstoned)"
    ])
  end

  it "warns on a stale snapshot" do
    enable(broken)
    broken.fail_reads = true
    expect(StandardFlags::Diagnostics.warnings(StandardFlags::Diagnostics.report))
      .to eq([ "runtime rules are stale: the last refresh failed (serving code defaults)" ])
  end

  describe StandardFlags::HealthCheck do
    it "fails when runtime rules are on and the tables are missing" do
      enable(broken)
      broken.ready = false
      expect(described_class.new.run).to include(status: :fail, error_class: "StandardFlags::RuntimeUnavailable",
                                                 error: /runtime rules are on but their tables are missing/)
    end

    it "warns on a stale snapshot" do
      enable(broken)
      broken.put_rule(:new_checkout, status: :running)
      StandardFlags::Runtime.snapshot
      broken.fail_reads = true
      StandardFlags::Runtime.clock = -> { 1e9 }
      expect(described_class.new.run[:warnings].first).to match(/\Aruntime rules are stale: the last refresh failed \(serving revision 1, [\d.]+s old\)\z/)
    end

    it "warns, not fails, when the store can't be reached, keeping the stale warning" do
      enable(broken)
      broken.put_rule(:new_checkout, status: :running)
      StandardFlags::Runtime.snapshot
      broken.fail_reads = true
      StandardFlags::Runtime.clock = -> { 1e9 }
      allow(broken).to receive(:ready?)
        .and_raise(StandardFlags::Runtime::StoreError.new("ready check failed", cause_class: "PG::ConnectionBad"))
      result = described_class.new.run
      expect(result).to include(status: :ok)
      expect(result[:warnings]).to include(
        "runtime rules store is unreachable (PG::ConnectionBad); flags keep serving the last good snapshot",
        a_string_starting_with("runtime rules are stale: the last refresh failed (serving revision 1,")
      )
      expect(StandardFlags::Diagnostics.report[:runtime]).to include(ready: false, unreachable: "PG::ConnectionBad")
    end

    it "names the error class when the store raises something else on ready?" do
      enable(broken)
      allow(broken).to receive(:ready?).and_raise("down")
      expect(StandardFlags::Diagnostics.report[:runtime]).to include(ready: false, unreachable: "RuntimeError")
      expect(described_class.new.run).to include(status: :ok)
    end

    it "passes on the store's own warnings" do
      enable(store)
      allow(store).to receive(:warnings).and_return([ "prepared statements are off" ])
      expect(described_class.new.run[:warnings]).to eq([ "prepared statements are off" ])
    end

    it "ignores a store whose warnings raise" do
      enable(store)
      allow(store).to receive(:warnings).and_raise("down")
      expect(described_class.new.run).not_to have_key(:warnings)
    end
  end

  describe StandardFlags::Tooling::List do
    it "adds a rule column and the snapshot's revision and age" do
      enable(store)
      store.put_rule(:new_checkout, status: :paused)
      store.put_rule(:mystery, status: :draft)
      lines = described_class.new.render.lines.map(&:strip)
      expect(lines.first).to match(/\Aruntime rules: revision 2, [\d.]+s old; rules for undeclared keys: mystery\z/)
      expect(lines[1].split).to eq(%w[key kind value reason env_var remove_by rule])
      expect(lines.find { |l| l.start_with?("new_checkout") }.split.last).to eq("paused")
      expect(lines.find { |l| l.start_with?("home_hero") }.split.last).to eq("-")
    end

    it "says when rules never loaded, or are stale" do
      enable(broken)
      broken.fail_reads = true
      expect(described_class.new.render.lines.first.strip).to eq("runtime rules: not loaded (serving code defaults)")
      broken.fail_reads = false
      StandardFlags::Runtime.reset!
      StandardFlags::Runtime.snapshot
      broken.fail_reads = true
      StandardFlags::Runtime.clock = -> { 1e9 }
      expect(described_class.new.render.lines.first).to match(/old, stale$/)
    end
  end
end
