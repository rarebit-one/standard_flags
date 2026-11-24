require "spec_helper"

RSpec.describe StandardFlags::Context do
  describe "client:" do
    it "normalises client: to a Client while Hash reads keep working" do
      context = described_class.new(client: { "platform" => "android", version: "1.4.0" })
      expect(context.client).to be_a(StandardFlags::Client)
      expect(context.client[:platform]).to eq("android")
      expect(described_class.new(client: StandardFlags::Client.new(platform: "android", version: "1.4.0")).cache_key)
        .to eq(context.cache_key)
      expect(described_class.new.client).to equal(StandardFlags::Client.empty)
    end

    it "carries a client through wrap" do
      account = Struct.new(:id).new(4)
      client = StandardFlags::Client.new(platform: "ios")
      wrapped = described_class.wrap(account, client: client)
      expect([ wrapped.target, wrapped.client ]).to eq([ account, client ])
      expect(described_class.wrap({ account: account }, client: { platform: "web" })).to have_attributes(actors: { account: account })
      expect(described_class.wrap(nil, client: { platform: "web" }).client.platform).to eq("web")
      expect(described_class.wrap(nil)).to equal(described_class.empty)
    end

    it "replaces a context's client, keeping everything else" do
      original = described_class.new(actors: { account: "a" }, env: "staging", client: { platform: "ios" })
      replaced = described_class.wrap(original, client: { platform: "android" })
      expect(replaced).to have_attributes(actors: { account: "a" }, env: "staging")
      expect(replaced.client.platform).to eq("android")
      expect(original.with_client(platform: "ios")).to equal(original)
    end
  end
end
