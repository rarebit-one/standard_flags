require "spec_helper"

RSpec.describe StandardFlags::Stores::AppStore do
  let(:now) { [ 1000.0 ] }
  let(:jobs) { [] }
  let(:store) do
    described_class.new(bundle_id: "com.example.app", country: "GB", clock: -> { now.first }, runner: ->(&job) { jobs << job })
  end
  let(:http) { instance_double(Net::HTTP) }
  let(:responses) { [] }

  def app
    StandardFlags::ClientApp.declare(:ios_app, platform: :ios)
  end

  def ok(*chunks)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      allow(response).to receive(:read_body) { |&block| chunks.each(&block) }
    end
  end

  def lookup(version)
    ok(JSON.generate("resultCount" => 1, "results" => [ { "bundleId" => "com.example.app", "version" => version } ]))
  end

  def run_jobs
    jobs.shift.call while jobs.any?
  end

  def failures
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("store_lookup_failed.standard_flags") { |*, payload| events << payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  before do
    allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }
    allow(http).to receive(:request) do |_request, &block|
      answer = responses.shift
      answer.is_a?(Exception) ? raise(answer) : block.call(answer)
    end
  end

  it "never waits: the first call answers nil and refreshes in the background" do
    responses << lookup("2.1.0")
    expect(store.call(app)).to be_nil
    expect(jobs.size).to eq(1)
    run_jobs
    expect(store.call(app)).to eq(StandardFlags::Version.parse("2.1.0"))
    expect(Net::HTTP).to have_received(:start)
      .with("itunes.apple.com", 443, use_ssl: true, open_timeout: 4.0, read_timeout: 4.0, write_timeout: 4.0, ssl_timeout: 4.0)
    expect(http).to have_received(:request).with(having_attributes(path: "/lookup?bundleId=com.example.app&country=gb"))
  end

  it "starts one refresh at a time, and the next after the ttl" do
    responses.push(lookup("2.1.0"), lookup("2.2"))
    3.times { store.call(app) }
    expect(jobs.size).to eq(1)
    run_jobs
    now[0] += 3599
    store.call(app)
    expect(jobs).to be_empty
    now[0] += 1
    expect(store.call(app).to_s).to eq("2.1.0")
    run_jobs
    expect(store.call(app).to_s).to eq("2.2.0")
  end

  it "keeps the last good answer through failures, backing off up to the ttl" do
    responses.push(lookup("2.1.0"), *Array.new(6) { Net::OpenTimeout.new })
    store.refresh!(app)
    waits = []
    6.times do
      now[0] += 100_000
      store.call(app)
      started = now.first
      run_jobs
      expect(store.call(app).to_s).to eq("2.1.0")
      waits << (store.instance_variable_get(:@next_at) - started)
    end
    expect(waits).to eq([ 300, 600, 1200, 2400, 3600, 3600 ])
  end

  it "reports every kind of failure as a reason, naming the client" do
    responses.push(Net::HTTPServiceUnavailable.new("1.1", "503", "x"), ok("not json"), ok(JSON.generate("results" => [])),
                   lookup("2.1.0.4"), ok("{", " " * 200_000, " " * 200_000))
    events = failures { 5.times { store.refresh!(app) } }
    expect(events.map { |event| event[:reason] })
      .to eq([ "HTTP 503", "JSON::ParserError", "no usable version", "no usable version", "response too large" ])
    expect(events.first).to eq(store: "StandardFlags::Stores::AppStore", client: :ios_app, reason: "HTTP 503")
    expect(store.call(app)).to be_nil
  end

  it "gives each fetch one overall deadline" do
    slow = described_class.new(bundle_id: "com.example.app", deadline: 0.05, runner: ->(&job) { job.call })
    allow(Net::HTTP).to receive(:start) { sleep 1 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    events = failures { slow.refresh! }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(events.map { |event| event[:reason] }).to eq([ "Timeout::Error" ])
  end

  it "runs refreshes on a thread by default, so a stalled store never holds up a request" do
    gate = Queue.new
    threads = []
    default = described_class.new(bundle_id: "com.example.app", runner: ->(&job) { threads << described_class::THREAD_RUNNER.call(&job) })
    allow(Net::HTTP).to receive(:start) do |*, &block|
      gate.pop
      block.call(http)
    end
    responses << lookup("3.0.0")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(default.call(app)).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.1
    gate << :go
    threads.each(&:join)
    expect(default.call(app).to_s).to eq("3.0.0")
  end

  it "starts its own refresh in a forked child, whatever the parent was doing" do
    store.call(app)
    expect(jobs.size).to eq(1)
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    store.call(app)
    expect(jobs.size).to eq(2)
  end

  it "backs off a runner that can't start the refresh, as it would a failed fetch" do
    broken = described_class.new(bundle_id: "com.example.app", clock: -> { now.first },
                                 runner: ->(&_job) { raise ThreadError, "can't create Thread" })
    events = failures { 100.times { expect(broken.call(app)).to be_nil } }
    expect(events).to eq([ { store: "StandardFlags::Stores::AppStore", client: :ios_app, reason: "ThreadError" } ])
    now[0] += 300
    expect(failures { broken.call(app) }.size).to eq(1)
    now[0] += 300
    expect(failures { broken.call(app) }).to eq([])
  end

  it "reports a failure after the deadline has ended, so a slow subscriber isn't cut short" do
    slow = described_class.new(bundle_id: "com.example.app", deadline: 0.05, runner: ->(&job) { job.call })
    responses << Net::HTTPServiceUnavailable.new("1.1", "503", "x")
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("store_lookup_failed.standard_flags") do |*, payload|
      sleep 0.1
      seen << payload[:reason]
    end
    slow.refresh!
    expect(seen).to eq([ "HTTP 503" ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # A local server that accepts connections and never answers, so the TLS
  # handshake stalls. Yields its port; closes everything afterwards.
  def with_blackhole_server
    server = TCPServer.new("127.0.0.1", 0)
    held = []
    acceptor = Thread.new { loop { held << server.accept } }
    yield server.addr[1]
  ensure
    acceptor&.kill
    held&.each(&:close)
    server&.close
  end

  def open_sockets_to(port)
    ObjectSpace.each_object(TCPSocket).count { |socket| !socket.closed? && socket.remote_address.ip_port == port rescue false } # rubocop:disable Style/RescueModifier
  end

  it "leaves no socket open when a fetch stalls past its deadline" do
    allow(Net::HTTP).to receive(:start).and_call_original
    with_blackhole_server do |port|
      blackhole = described_class.new(bundle_id: "com.example.app", deadline: 0.2, runner: ->(&job) { job.call })
      blackhole.define_singleton_method(:uri) { URI("https://127.0.0.1:#{port}/lookup") }
      GC.disable
      expect(failures { 3.times { blackhole.refresh! } }.size).to eq(3)
      expect(open_sockets_to(port)).to eq(0)
    ensure
      GC.enable
    end
  end

  it "lets refresh! leave a running background refresh's claim alone" do
    store.call(app)
    responses << lookup("2.0.0")
    store.refresh!(app)
    store.call(app)
    expect(jobs.size).to eq(1)
  end

  it "works as a client's store_lookup" do
    responses << lookup("1.9.0")
    lookup_store = store
    StandardFlags.define do
      client :ios_app, platform: :ios, min_version: "2.0.0", since: "2026-11-01", store_lookup: lookup_store
    end
    lookup_store.refresh!
    result = StandardFlags::ClientStatus.for({ platform: "ios", version: "1.9.0" }, today: Date.new(2026, 12, 1))
    expect(result.to_h).to include("status" => "ok", "min_version" => "1.9.0")
  end

  it "validates its arguments and builds its URL" do
    expect { described_class.new(bundle_id: " ") }.to raise_error(ArgumentError, /bundle_id:/)
    expect { described_class.new(bundle_id: "x", country: "usa") }.to raise_error(ArgumentError, /country:/)
    expect(described_class.new(bundle_id: " com.example.app ").bundle_id).to eq("com.example.app")
    expect(store.uri.to_s).to eq("https://itunes.apple.com/lookup?bundleId=com.example.app&country=gb")
  end
end
