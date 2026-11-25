require "spec_helper"

RSpec.describe StandardFlags::Stores::AppStore do
  let(:now) { [ 1000.0 ] }
  let(:store) { described_class.new(bundle_id: "com.example.app", country: "GB", clock: -> { now.first }) }
  let(:http) { instance_double(Net::HTTP) }
  let(:responses) { [] }

  def ok(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap { |response| allow(response).to receive(:body).and_return(body) }
  end

  def lookup(version)
    ok(JSON.generate("resultCount" => 1, "results" => [ { "bundleId" => "com.example.app", "version" => version } ]))
  end

  before do
    allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }
    allow(http).to receive(:request) do
      answer = responses.shift
      answer.is_a?(Exception) ? raise(answer) : answer
    end
  end

  it "asks Apple's public lookup API with a short timeout and reads the version" do
    responses << lookup("2.1.0")
    expect(store.call).to eq(StandardFlags::Version.parse("2.1.0"))
    expect(Net::HTTP).to have_received(:start)
      .with("itunes.apple.com", 443, use_ssl: true, open_timeout: 2, read_timeout: 2, write_timeout: 2)
    expect(http).to have_received(:request).with(having_attributes(path: "/lookup?bundleId=com.example.app&country=gb"))
    expect(store.uri.to_s).to eq("https://itunes.apple.com/lookup?bundleId=com.example.app&country=gb")
  end

  it "caches an answer for an hour per process" do
    responses.push(lookup("2.1.0"), lookup("2.2"))
    store.call
    now[0] += 3599
    expect(store.call.to_s).to eq("2.1.0")
    now[0] += 1
    expect(store.call.to_s).to eq("2.2.0")
    expect(http).to have_received(:request).twice
  end

  def failures
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("store_lookup_failed.standard_flags") { |*, payload| events << payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "answers nil after a failure, and asks again after retry_after" do
    responses.push(Net::OpenTimeout.new, lookup("2.1.0"))
    events = failures do
      expect(store.call).to be_nil
      now[0] += 299
      expect(store.call).to be_nil
      now[0] += 1
      expect(store.call.to_s).to eq("2.1.0")
    end
    expect(events).to eq([ { store: "app_store", error_class: "Net::OpenTimeout" } ])
  end

  it "never raises: every kind of failure keeps the last good answer" do
    responses.push(lookup("2.1.0"), Net::HTTPServiceUnavailable.new("1.1", "503", "x"), ok("not json"),
                   ok(JSON.generate("results" => [])), lookup("2.1.0.4"), ok("{}" + (" " * 300_000)))
    events = failures do
      6.times do
        expect(store.call.to_s).to eq("2.1.0")
        now[0] += 3600
      end
    end
    expect(events.map { |event| event[:error_class] })
      .to eq([ "HTTP 503", "JSON::ParserError", "no usable version", "no usable version", "response too large" ])
  end

  it "lets only one thread ask at a time; the others use what is cached" do
    gate = Queue.new
    allow(http).to receive(:request) do
      gate.pop
      lookup("3.0.0")
    end
    asker = Thread.new { store.call }
    sleep 0.01 until store.instance_variable_get(:@mutex).locked?
    expect(store.call).to be_nil
    gate << :go
    expect(asker.value.to_s).to eq("3.0.0")
    expect(http).to have_received(:request).once
  end

  it "takes the ClientApp it is asked about and ignores it, so it works as a lookup" do
    responses << lookup("1.9.0")
    StandardFlags.define { client :ios_app, platform: :ios, min_version: "2.0.0", since: "2026-11-01" }
    StandardFlags.config.client_store_lookup = store
    result = StandardFlags::ClientStatus.for({ platform: "ios", version: "1.9.0" }, today: Date.new(2026, 12, 1))
    expect(result.to_h).to include("status" => "ok", "min_version" => "1.9.0")
  end

  it "validates its arguments" do
    expect { described_class.new(bundle_id: " ") }.to raise_error(ArgumentError, /bundle_id:/)
    expect { described_class.new(bundle_id: "x", country: "usa") }.to raise_error(ArgumentError, /country:/)
    expect(described_class.new(bundle_id: " com.example.app ").bundle_id).to eq("com.example.app")
  end
end
