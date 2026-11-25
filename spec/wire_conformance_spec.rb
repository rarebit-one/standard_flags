require "spec_helper"

# Runs conformance/wire: delivery.json (what the server tells a client) and
# client_state.json (what a client reads from it, through the reference
# client in spec/support/helpers/client_state.rb). Kotlin and TypeScript
# client libraries run the same files; see conformance/README.md.
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
end
