require "spec_helper"

RSpec.describe StandardFlags::MCP, registry: OperationHelpers::REGISTRY do
  describe "client:" do
    let(:user) { OperationHelpers::User.new(7) }
    let(:store) { StandardFlags::Runtime::MemoryStore.new }

    before do
      StandardFlags.config.runtime_rules = true
      StandardFlags.config.runtime_store = store
      StandardFlags.config.authorize = ->(*) { true }
      store.put_rule(:global_banner, status: :running, fallthrough_value: "off")
    end

    it "evaluates list_flags and get_flag for a Client, a Hash or a callable, and refuses anything else" do
      seen = []
      allow(StandardFlags::Evaluator).to receive(:evaluate).and_wrap_original do |original, registry, key, context|
        seen << context.client.to_h
        original.call(registry, key, context)
      end
      described_class.tool("get_flag", client: { platform: "ios" }).call({ "key" => "global_banner" }, actor: user)
      described_class.tool("get_flag", client: ->(actor) { { platform: "web", version: actor.id.to_s } })
                     .call({ "key" => "global_banner" }, actor: user)
      described_class.tools(client: -> { StandardFlags::Client.new(platform: "android") }).first.call({}, actor: user)
      described_class.tool("get_flag").call({ "key" => "global_banner" }, actor: user)
      expect(seen.uniq).to eq([ { platform: "ios" }, { platform: "web", version: "7" }, { platform: "android" }, {} ])
      expect { described_class.tool("get_flag", client: "ios") }.to raise_error(ArgumentError, /client: must be/)
    end
  end
end
