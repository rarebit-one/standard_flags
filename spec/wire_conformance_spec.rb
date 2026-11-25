require "spec_helper"

# Runs conformance/wire: delivery.json (what the server tells a client),
# client_state.json (what a client reads from it, through the reference
# client in spec/support/helpers/client_state.rb) and client_status.json
# (what GET /client/status answers). Kotlin and TypeScript client libraries
# run the same files; see conformance/README.md.
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

  describe "client_status.json" do
    fixture = ConformanceRegistry.load(ConformanceRegistry.path("wire/client_status.json"))
    header_names = { "platform" => "X-Client-Platform", "version" => "X-Client-Version", "build" => "X-Client-Build" }

    fixture.fetch("cases").each do |example|
      it example.fetch("name") do
        clients = fixture.fetch("clients")
        StandardFlags.define do
          clients.each do |entry|
            attributes = entry.except("name", "grace_days").transform_keys(&:to_sym)
            attributes[:grace] = entry["grace_days"] if entry.key?("grace_days")
            client entry.fetch("name"), **attributes
          end
        end
        headers = example.fetch("client").to_h { |field, value| [ header_names.fetch(field), value.to_s ] }
        lookup = example["store_lookup"]&.transform_keys(&:to_sym)&.transform_values { |version| ->(_app) { version } }
        result = StandardFlags::ClientStatus.for(
          StandardFlags::Client.from_headers(headers), group: example["group"]&.to_sym,
          today: Date.iso8601(example.fetch("today") { fixture.fetch("today") }), env: example.fetch("env_vars", {}), lookup: lookup
        )

        expect(result.to_h).to eq(example.fetch("expected"))
      end
    end

    it "keeps the wire cases free of ENV pins and store lookups" do
      wire = fixture.fetch("cases").reject { |example| example["scope"] == "server" }
      expect(wire.map { |example| example.keys & %w[env_vars store_lookup] }.flatten).to eq([])
      expect(fixture.fetch("cases").map { |example| example.dig("expected", "status") }.uniq)
        .to match_array(StandardFlags::ClientStatus::STATUSES)
    end
  end
end
