require "spec_helper"
require "timeout"

RSpec.describe StandardFlags::Runtime::EvaluationTracker, registry: RuntimeHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:time) { [ 0.0 ] }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    StandardFlags::Runtime.clock = -> { time.first }
    store.put_rule(:new_checkout, status: :running, fallthrough_value: true)
    store.put_rule(:strict_gates, status: :paused)
  end

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  # Evaluates both flags once per second for `seconds`.
  def run_for(seconds)
    seconds.times do
      unit_of_work do
        StandardFlags.evaluate(:new_checkout, for: for_account(1))
        StandardFlags.evaluate(:strict_gates, for: for_account(1))
        StandardFlags.evaluate(:global_banner)
      end
      time[0] += 1
    end
  end

  it "writes evaluated rule keys at most once per interval, in one write" do
    StandardFlags.config.evaluation_tracking_interval = 60
    run_for(30)
    expect(store.reads[:touch_evaluated]).to eq(1)
    expect(store.rule(:new_checkout).last_evaluated_at).to be_within(5).of(Time.now)
    expect(store.rule(:strict_gates).last_evaluated_at).not_to be_nil
    run_for(60)
    expect(store.reads[:touch_evaluated]).to eq(2)
  end

  it "writes nothing during an evaluation, only when the unit of work ends" do
    during = nil
    unit_of_work do
      StandardFlags.evaluate(:new_checkout, for: for_account(1))
      time[0] += 7_200 # a refresh is due, and so is the tracker
      StandardFlags.evaluate(:new_checkout, for: for_account(1))
      during = [ store.reads[:touch_evaluated], StandardFlags::Runtime.tracker.pending ]
    end
    expect(during).to eq([ 0, %i[new_checkout] ])
    expect([ store.reads[:touch_evaluated], StandardFlags::Runtime.tracker.pending ]).to eq([ 1, [] ])
  end

  it "writes nothing when evaluating outside a unit of work" do
    StandardFlags.evaluate(:new_checkout, for: for_account(1))
    time[0] += 7_200
    StandardFlags.evaluate(:new_checkout, for: for_account(1))
    expect(store.reads[:touch_evaluated]).to eq(0)
  end

  it "flushes once when many threads end their units of work together" do
    StandardFlags.evaluate(:new_checkout, for: for_account(1))
    threads = Array.new(8) { Thread.new { StandardFlags::Runtime.unit_of_work_complete! } }
    threads.each(&:join)
    expect(store.reads[:touch_evaluated]).to eq(1)
  end

  it "never raises from the end of a unit of work" do
    StandardFlags.evaluate(:new_checkout, for: for_account(1))
    allow(StandardFlags::Runtime).to receive(:store).and_raise(IOError)
    expect(StandardFlags::Runtime.unit_of_work_complete!).to be_nil
  end

  it "can be turned off" do
    StandardFlags.config.track_evaluations = false
    run_for(30)
    expect(store.reads[:touch_evaluated]).to eq(0)
    expect(StandardFlags::Runtime.tracker.pending).to eq([])
  end

  it "swallows a failing write, reports it once, and tries again next interval" do
    StandardFlags.config.evaluation_tracking_interval = 10
    allow(store).to receive(:touch_evaluated).and_raise(StandardFlags::Runtime::StoreError.new("evaluation tracking failed: PG::Error", cause_class: "PG::Error"))
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("evaluation_tracking_failed.standard_flags") { |*, payload| events << payload }

    errors = collect_errors { run_for(35) }
    expect(store).to have_received(:touch_evaluated).exactly(4).times # t=0, 10, 20, 30
    expect(errors.reports.map { |r| r[:context] }).to eq([ { runtime: "evaluation_tracking" } ])
    expect(events.first).to eq(error_class: "PG::Error")
    expect([ StandardFlags.on?(:new_checkout, for: for_account(1)), StandardFlags::Runtime.tracker.pending ])
      .to eq([ true, %i[new_checkout strict_gates] ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "keeps the keys when the store skips the write, and tries again when the next unit of work ends" do
    allow(store).to receive(:touch_evaluated).and_return(nil)
    run_for(12)
    expect(store).to have_received(:touch_evaluated).exactly(12).times
    expect(StandardFlags::Runtime.tracker.pending).to eq(%i[new_checkout strict_gates])
  end

  it "keeps the keys it inherited and its lock after a fork" do
    tracker = described_class.new
    tracker.track(:new_checkout)
    lock = tracker.instance_variable_get(:@mutex)
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    tracker.track(:strict_gates)
    expect(tracker.pending).to eq(%i[new_checkout strict_gates])
    expect(tracker.instance_variable_get(:@mutex)).to equal(lock)
  end

  # Forks while another thread holds `lock`; true when the child's block
  # returns truthy within 5 seconds.
  def fork_while_held(lock, &child)
    held = Queue.new
    release = Queue.new
    holder = Thread.new { lock.synchronize { held << true and release.pop } }
    held.pop
    pid = fork { exit!((Timeout.timeout(5, &child) rescue false) ? 0 : 1) } # rubocop:disable Style/RescueModifier
    release << true
    holder.join
    Process.wait2(pid).last.exitstatus.zero?
  end

  it "tracks in a forked child even if another thread held the lock at fork time", if: Process.respond_to?(:fork) do
    tracker = described_class.new
    tracker.track(:new_checkout)
    forked = fork_while_held(tracker.instance_variable_get(:@mutex)) do
      tracker.track(:strict_gates)
      tracker.pending == %i[new_checkout strict_gates]
    end
    expect(forked).to be(true)
  end

  it "is a no-op on a store that doesn't track evaluations" do
    plain = Class.new(StandardFlags::Runtime::Store) do
      def revision = 0
      def load = StandardFlags::Runtime::Loaded.new(rules: [ StandardFlags::Runtime::Rule.build(key: :new_checkout, salt: "s", status: "running") ], cohorts: [])
      def memberships(*) = []
    end.new
    StandardFlags.config.runtime_store = plain
    expect { run_for(12) }.not_to raise_error
  end
end
