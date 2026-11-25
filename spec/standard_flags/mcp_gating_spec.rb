require "spec_helper"

RSpec.describe StandardFlags::MCP::Gated do
  let(:account) { Struct.new(:id) }
  let(:operator) { Struct.new(:id, :account).new(7, account.new(1)) }
  let(:gated) { tool_class { requires_flag :summaries }.new }
  let(:open) { tool_class.new }

  before do
    StandardFlags.define do
      unit :account, from: ->(ctx) { ctx.account }
      flag :summaries, owner: "assistant", remove_by: "2027-01-01", final: true, unit: :account, expose: { mcp: :threadSummaries }
      kill_switch :ai_assistant, owner: "assistant"
    end
  end

  def tool_class(&block)
    Class.new do
      include StandardFlags::MCP::Gated

      class_eval(&block) if block

      def name = "summarise_thread"
      def description = "Summarise a thread"
      def input_schema = { "type" => "object", "properties" => {} }
      def call(arguments, actor:) = { "summary" => "for #{actor.id}", "arguments" => arguments }
    end
  end

  it "runs the tool while its flags are on" do
    with_flag(:summaries, true) do
      expect(gated.call({ "id" => 1 }, actor: operator)).to eq("summary" => "for 7", "arguments" => { "id" => 1 })
    end
  end

  it "answers feature_disabled without running the tool while a flag is off" do
    ran = []
    klass = tool_class { requires_flag :summaries }
    klass.define_method(:call) { |arguments, actor:| ran << [ arguments, actor ] }
    expect(klass.new.call({}, actor: operator))
      .to eq("error" => { "code" => "feature_disabled", "message" => "threadSummaries is disabled" })
    expect(ran).to be_empty
    with_flag(:summaries, true) { klass.new.call({}, actor: operator) }
    expect(ran.size).to eq(1)
  end

  it "needs every declared flag, a superclass's included" do
    parent = tool_class { requires_flag :ai_assistant }
    child = Class.new(parent) { requires_flag :summaries }
    expect(child.standard_flags_requirements.map(&:key)).to eq(%i[ai_assistant summaries])
    with_flag(:summaries, true) { expect(child.new.call({}, actor: operator)).to include("summary") }
    StandardFlags.config.env_source = { "STANDARD_FLAGS_AI_ASSISTANT" => "off" }
    with_flag(:summaries, true) { expect(child.new.call({}, actor: operator).dig("error", "message")).to eq("ai_assistant is disabled") }
  end

  it "evaluates for the actor by default, or for: and client: given as values or lambdas" do
    store = StandardFlags::Runtime::MemoryStore.new
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    store.put_rule(:summaries, status: :running, percentage_bps: 10_000, fallthrough_value: "off",
                               conditions: { "platforms" => [ "ios" ] })
    StandardFlags::Memo.clear!

    by_actor = tool_class { requires_flag :summaries, client: -> { StandardFlags::Client.new(platform: "ios") } }.new
    expect(by_actor.call({}, actor: operator)).to include("summary")

    by_lambda = tool_class { requires_flag :summaries, for: ->(actor) { { account: actor.account } }, client: ->(_actor) { { platform: "android" } } }.new
    expect(by_lambda.call({}, actor: operator)).to include("error")

    other = account.new(2)
    by_value = tool_class { requires_flag :summaries, for: { account: other }, client: { platform: "ios" } }.new
    expect(by_value.call({}, actor: operator)).to include("summary")
  end

  describe "StandardFlags::MCP.visible" do
    it "drops gated tools whose flags are off and keeps the rest" do
      tools = [ gated, open, *StandardFlags::MCP.tools ]
      expect(StandardFlags::MCP.visible(tools, actor: operator).map(&:name).first(2)).to eq(%w[summarise_thread list_flags])
      expect(StandardFlags::MCP.visible(tools, actor: operator).size).to eq(13)
      with_flag(:summaries, true) { expect(StandardFlags::MCP.visible(tools, actor: operator).size).to eq(14) }
    end

    it "evaluates every gate for context: and client: when given" do
      store = StandardFlags::Runtime::MemoryStore.new
      StandardFlags.config.runtime_rules = true
      StandardFlags.config.runtime_store = store
      store.put_rule(:summaries, status: :running, percentage_bps: 10_000, fallthrough_value: "off", conditions: { "platforms" => [ "web" ] })
      StandardFlags::Memo.clear!
      expect(StandardFlags::MCP.visible([ gated ], actor: operator, client: { platform: "web" })).to eq([ gated ])
      expect(StandardFlags::MCP.visible([ gated ], context: { account: account.new(3) }, client: { platform: "ios" })).to be_empty
      expect(StandardFlags::MCP.visible([ gated ], context: StandardFlags::Context.new(actors: { account: account.new(3) },
                                                                                       client: { platform: "web" }))).to eq([ gated ])
    end
  end

  it "builds the tool error from a FeatureDisabled" do
    expect(StandardFlags::MCP.feature_disabled(StandardFlags::FeatureDisabled.new(:ai_assistant)))
      .to eq("error" => { "code" => "feature_disabled", "message" => "ai_assistant is disabled" })
  end
end
