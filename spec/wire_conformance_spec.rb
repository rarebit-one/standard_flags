require "spec_helper"
require "json_schemer"

# Runs conformance/wire: delivery.json (what the server tells a client),
# client_state.json (what a client reads from it, through the reference
# client in spec/support/helpers/client_state.rb), client_status.json (what
# GET /client/status answers) and manifest_check.json (what
# standard_flags:manifest:check and a client's contract check decide).
# Kotlin and TypeScript client libraries run the same files; see
# conformance/README.md.
RSpec.describe "wire conformance fixtures" do
  describe "delivery.json" do
    fixture = ConformanceRegistry.load(ConformanceRegistry.path("wire/delivery.json"))

    fixture.fetch("cases").each do |example|
      it example.fetch("name") do
        body = ConformanceRegistry.deliver(fixture, example)
        expected = example.fetch("expected")

        expect(body).to eq("flags" => expected.fetch("flags"), "metadata" => { "version" => expected.fetch("etag") })
        json = JSON.generate(body)
        fixture.fetch("never_on_wire").each { |secret| expect(json).not_to include(secret) }
      end
    end

    it "pins the ETag relations it names" do
      named = fixture.fetch("cases").to_h { |example| [ example.fetch("name"), example.fetch("expected").fetch("etag") ] }
      fixture.fetch("cases").each do |example|
        etag = named.fetch(example.fetch("name"))
        expect(etag).to eq(named.fetch(example["etag_same_as"])) if example["etag_same_as"]
        Array(example["etag_differs_from"]).each { |other| expect(etag).not_to eq(named.fetch(other)) }
      end
    end
  end

  describe "client_state.json" do
    fixture = ConformanceRegistry.load(ConformanceRegistry.path("wire/client_state.json"))

    fixture.fetch("cases").each do |example|
      it example.fetch("name") do
        client = ClientStateReference.new(example.fetch("declared") { fixture.fetch("declared") }, fixture.fetch("limits"))
        example.fetch("steps").each_with_index do |step, index|
          accepted =
            if step["not_modified"] then client.not_modified
            elsif step.key?("raw") then client.receive(step["raw"])
            else client.receive(JSON.generate(step["payload"]))
            end

          actual = { "accepted" => accepted, "version" => client.version, "reads" => client.reads }
          expect(actual).to eq(step.fetch("expected")), "step #{index + 1}"
        end
      end
    end
  end

  {
    "wire/client_status.json" => "wire", "upgrade/client_status_server.json" => "server"
  }.each do |path, scope|
    describe path do
      fixture = ConformanceRegistry.load(ConformanceRegistry.path(path))

      fixture.fetch("cases").each do |example|
        it example.fetch("name") do
          expect(ConformanceRegistry.client_status(fixture, example)).to eq(example.fetch("expected"))
        end
      end

      it "is #{scope}-scoped, and only a server file uses ENV pins or store lookups" do
        expect(fixture.fetch("scope")).to eq(scope)
        extras = fixture.fetch("cases").flat_map { |example| example.keys & %w[env_vars store_lookup scope] }
        expect(extras.empty?).to be(scope == "wire")
      end
    end
  end

  it "covers every status between the client_status files" do
    statuses = %w[wire/client_status.json upgrade/client_status_server.json].flat_map do |path|
      ConformanceRegistry.load(ConformanceRegistry.path(path)).fetch("cases").map { |example| example.dig("expected", "status") }
    end
    expect(statuses.uniq).to match_array(StandardFlags::ClientStatus::STATUSES)
  end
  describe "manifest_check.json" do
    fixture = ConformanceRegistry.load(ConformanceRegistry.path("wire/manifest_check.json"))
    schema = JSONSchemer.schema(Pathname.new(ConformanceRegistry.path("schema/manifest.schema.json")))

    fixture.fetch("cases").each do |example|
      it example.fetch("name") do
        today = Date.iso8601(example.fetch("today") { fixture.fetch("today") })
        result = StandardFlags::Tooling::ManifestCheck.new(committed: example.fetch("committed"), current: example.fetch("current"),
                                                           current_render: "", today: today).call
        actual =
          if result.status == :unreadable
            { "status" => "invalid", "invalid" => result.error_source.to_s }
          else
            { "status" => result.status.to_s, "stale" => result.stale, "removed_wires" => result.removed_wires.map(&:to_h),
              "type_changes" => result.type_changes.map(&:to_h), "audiences_made_private" => result.audiences_made_private.map(&:to_h) }
          end

        expect(actual).to eq(example.fetch("expected"))
      end
    end

    it "holds only manifests that validate, version 1 only in server cases, apart from the invalid ones" do
      fixture.fetch("cases").each do |example|
        %w[committed current].each do |side|
          manifest = example.fetch(side)
          if example.dig("expected", "invalid") == side
            expect { StandardFlags::Tooling::Manifest.read(manifest) }.to raise_error(StandardFlags::Tooling::Manifest::Unreadable)
          elsif manifest["version"] == 1
            expect(example["scope"]).to eq("server"), example["name"]
          else
            expect(schema.validate(manifest).map { |error| error["error"] }).to eq([]), example["name"]
          end
        end
      end
    end
  end
end
