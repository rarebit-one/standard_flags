require "spec_helper"

RSpec.describe StandardFlags::Client do
  def capture_invalid(&block)
    seen = []
    callback = ->(_name, _start, _finish, _id, payload) { seen << payload }
    ActiveSupport::Notifications.subscribed(callback, "client_invalid.standard_flags", &block)
    seen
  end

  describe ".from_headers" do
    it "reads the platform, version and build headers" do
      client = described_class.from_headers({ "X-Client-Platform" => "Android", "X-Client-Version" => " 1.4.0 ", "X-Client-Build" => "381" })
      expect(client).to have_attributes(platform: "android", version: StandardFlags::Version.parse("1.4.0"), build: 381)
      expect(client.to_h).to eq(platform: "android", version: "1.4.0", build: "381")
    end

    it "reads a Rack env and lower-case names" do
      expect(described_class.from_headers({ "HTTP_X_CLIENT_PLATFORM" => "ios", "HTTP_X_CLIENT_VERSION" => "2.1" }).to_h)
        .to eq(platform: "ios", version: "2.1")
      expect(described_class.from_headers({ "x-client-build" => "12" }).build).to eq(12)
    end

    it "reads ActionDispatch headers" do
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_CLIENT_PLATFORM" => "web", "HTTP_X_CLIENT_VERSION" => "3.0.0"))
      expect(described_class.from_headers(request.headers).to_h).to eq(platform: "web", version: "3.0.0")
    end

    it "gives the shared empty client when no header is sent" do
      expect(capture_invalid { expect(described_class.from_headers({})).to equal(described_class.empty) }).to be_empty
      expect(described_class.from_headers({ "X-Client-Version" => "  " })).to be_empty
    end

    it "drops values that fail and emits client_invalid without raising or reporting" do
      errors = collect_errors do
        seen = capture_invalid do
          client = described_class.from_headers({ "X-Client-Platform" => "tvos", "X-Client-Version" => "1.4.0.1",
                                                "X-Client-Build" => "-3" })
          expect(client).to equal(described_class.empty)
        end
        expect(seen).to eq([ { field: :platform, header: "X-Client-Platform" }, { field: :version, header: "X-Client-Version" },
                             { field: :build, header: "X-Client-Build" } ])
      end
      expect(errors.reports).to be_empty
    end

    it "keeps the fields that parse" do
      client = described_class.from_headers({ "X-Client-Platform" => "ios", "X-Client-Version" => "v2", "X-Client-Build" => "9" * 200 })
      expect(client.to_h).to eq(platform: "ios")
    end

    it "takes configured header names and platforms" do
      StandardFlags.config.client_headers = { platform: "X-App-OS", version: "X-App-Version" }
      StandardFlags.config.client_platforms = %i[TVOS]
      client = described_class.from_headers({ "X-App-OS" => "tvOS", "X-App-Version" => "1.0", "X-Client-Build" => "4" })
      expect(client.to_h).to eq(platform: "tvos", version: "1.0")
    end

    it "logs a dropped value at debug, naming the header and never the value" do
      io = StringIO.new
      line = StandardFlags::Notifiers::Logger.new(Logger.new(io)).call("client_invalid.standard_flags", field: :version, header: "X-Client-Version")
      expect(line).to eq("ignored X-Client-Version: not a valid client version")
      expect(io.string).to include("DEBUG").and include("[standard_flags] ignored X-Client-Version")
    end

    it "survives headers that raise" do
      headers = Object.new.tap { |h| h.define_singleton_method(:[]) { |_| raise "boom" } }
      expect(described_class.from_headers(headers)).to be_empty
    end
  end

  describe "the Hash form" do
    it "keeps what it is given, as 0.2.2 did, and parses the typed readers" do
      client = described_class.new(platform: " Android ", version: "not-a-version", build: 12, channel: "beta")
      expect(client.to_h).to eq(platform: " Android ", version: "not-a-version", build: 12, channel: "beta")
      expect(client).to have_attributes(platform: "android", version: nil, build: 12)
      expect(client[:channel]).to eq("beta")
      expect(client["platform"]).to eq(" Android ")
    end

    it "equals another client or Hash with the same attributes" do
      client = described_class.new(platform: "ios", version: "2.0")
      same = described_class.new("platform" => "ios", "version" => "2.0")
      expect([ client == same, client == same.to_h, client.eql?(same), client.hash == same.hash ]).to all(be(true))
      expect([ client == described_class.new(platform: "ios"), client == "ios", client.eql?(client.to_h) ]).to all(be(false))
      expect(client.inspect).to eq('#<StandardFlags::Client platform="ios" version="2.0">')
    end

    it "wraps clients, Hashes and nil, and refuses anything else" do
      client = described_class.new(platform: "ios")
      expect(described_class.wrap(client)).to equal(client)
      expect(described_class.wrap(nil)).to equal(described_class.empty)
      expect(described_class.wrap({})).to equal(described_class.empty)
      expect(described_class.wrap("platform" => "web").platform).to eq("web")
      expect { described_class.wrap("ios") }.to raise_error(ArgumentError, /client: must be/)
    end
  end
end
