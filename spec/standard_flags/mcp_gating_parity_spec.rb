require "spec_helper"

# The gate holds however a tool is written and called: subclasses, a nil
# actor, FeatureDisabled raised inside the tool, and list/call parity.
RSpec.describe StandardFlags::MCP do
  let(:account) { Struct.new(:id) }
  let(:operator) { Struct.new(:id, :account).new(7, account.new(1)) }
  let(:store) { StandardFlags::Runtime::MemoryStore.new }

  before do
    StandardFlags.define do
      unit :account, from: ->(ctx) { ctx.account }
      flag :summaries, owner: "assistant", remove_by: "2027-01-01", final: true, unit: :account,
                       expose: { web: :summaries, mcp: :threadSummaries }
    end
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def rule!(**attributes)
    store.put_rule(:summaries, status: :running, percentage_bps: 10_000, fallthrough_value: "off", **attributes)
    StandardFlags::Memo.clear!
  end

  def tool_class(&block)
    Class.new do
      include StandardFlags::MCP::Gated

      class_eval(&block) if block

      def name = "summarise_thread"
      def call(_arguments, actor:) = { "ran" => actor&.id }
    end
  end

  describe "a gated tool's subclasses" do
    it "stay gated when they define their own call" do
      rule!(fallthrough_value: "off", percentage_bps: 0)
      parent = tool_class { requires_flag :summaries }
      child = Class.new(parent) { def call(_arguments, actor:) = { "ran" => "child" } }
      grandchild = Class.new(child) { def call(_arguments, actor:) = { "ran" => "grandchild" } }
      expect(described_class.visible([ child.new, grandchild.new ], actor: operator)).to be_empty
      expect([ child.new.call({}, actor: operator), grandchild.new.call({}, actor: operator) ].map { |r| r.dig("error", "code") })
        .to eq(%w[feature_disabled feature_disabled])
    end
  end

  describe "the gate's cost" do
    def readers_per_call(tool)
      count = 0
      allow(StandardFlags).to receive(:reader).and_wrap_original { |original, **kwargs| (count += 1) && original.call(**kwargs) }
      tool.call({}, actor: operator)
      count
    end

    it "is one evaluation per call, however deep the subclasses that call super" do
      rule!
      parent = tool_class { requires_flag :summaries }
      deepest = (1..4).reduce(parent) { |klass, _| Class.new(klass) { def call(arguments, actor:) = super } }
      expect([ readers_per_call(parent.new), readers_per_call(deepest.new) ]).to eq([ 1, 1 ])
      expect(deepest.new.call({}, actor: operator)).to eq("ran" => 7)
      expect(StandardFlags::MCP::Gated::PASSED_KEY.then { |key| ActiveSupport::IsolatedExecutionState[key] }).to eq([])
    end

    it "still gates another tool called from inside a tool" do
      rule!(fallthrough_value: "off", percentage_bps: 0)
      inner = tool_class { requires_flag :summaries }.new
      outer = Class.new { def initialize(inner) = (@inner = inner); def call(_arguments, actor:) = @inner.call({}, actor: actor) }.new(inner)
      expect(described_class.call(outer, {}, actor: operator).dig("error", "code")).to eq("feature_disabled")
    end
  end

  describe "listing and calling" do
    let(:gated) { tool_class { requires_flag :summaries, for: ->(actor) { { account: actor.account } } }.new }
    let(:old_ios) { { platform: "ios", version: "1.0.0" } }

    before { rule!(conditions: { "versions" => { "ios" => ">=2.0.0" } }) }

    it "agree for the same client: a tool hidden from an old build is refused to it" do
      expect(described_class.visible([ gated ], actor: operator, client: old_ios)).to be_empty
      expect(described_class.call(gated, {}, actor: operator, client: old_ios).dig("error", "code")).to eq("feature_disabled")
    end

    it "agree for the same context, and a call with no override reads as visible with none" do
      new_ios = { platform: "ios", version: "2.1.0" }
      expect(described_class.visible([ gated ], actor: operator, client: new_ios)).to eq([ gated ])
      expect(described_class.call(gated, {}, actor: operator, client: new_ios)).to eq("ran" => 7)
      context = StandardFlags::Context.new(actors: { account: account.new(2) }, client: old_ios)
      expect(described_class.visible([ gated ], context: context)).to be_empty
      expect(described_class.call(gated, {}, actor: operator, context: context)).to include("error")
      expect([ described_class.visible([ gated ], actor: operator), gated.call({}, actor: operator) ]).to eq([ [ gated ], { "ran" => 7 } ])
    end

    it "restore the outer scope after a call, even one that raises" do
      raising = Class.new { def call(_arguments, actor:) = raise(ArgumentError, "boom") }.new
      expect { described_class.call(raising, {}, actor: operator, client: old_ios) }.to raise_error(ArgumentError)
      expect(StandardFlags::MCP::Gated.scope).to be_nil
    end
  end

  it "resolves a nil actor through config.actor_resolver, as the gem's own tools do" do
    denied = Struct.new(:id, :account).new(9, account.new(9))
    rule!(fallthrough_value: "on")
    store.add_member(unit: :account, unit_key: "9", value: false, rule: :summaries)
    StandardFlags::Memo.clear!
    StandardFlags.config.actor_resolver = -> { denied }
    gated = tool_class { requires_flag :summaries, for: ->(actor) { { account: actor.account } } }.new
    expect(described_class.visible([ gated ], actor: nil)).to be_empty
    expect(gated.call({}, actor: nil).dig("error", "code")).to eq("feature_disabled")
  end

  describe "a FeatureDisabled raised inside a tool" do
    it "comes back as the feature_disabled error from a gated tool, an ungated one and a gem Tool" do
      rule!(fallthrough_value: "off", percentage_bps: 0)
      gated = Class.new(tool_class) { def call(_arguments, actor:) = StandardFlags.require!(:summaries) }.new
      ungated = Class.new { def call(_arguments, actor:) = StandardFlags.require!(:summaries) }.new
      gem_tool = Class.new(StandardFlags::MCP::Tool) do
        tool_name "probe"
        schema({})
        def perform(_args) = StandardFlags.require!(:summaries)
      end.new
      errors = collect_errors do
        results = [ gated.call({}, actor: operator), described_class.call(ungated, {}, actor: operator),
                    gem_tool.call({}, actor: operator) ]
        expect(results).to all(eq("error" => { "code" => "feature_disabled", "message" => "summaries is disabled" }))
      end
      expect(errors.reports).to be_empty
    end
  end

  it "names the :mcp wire name in the gate's error" do
    rule!(fallthrough_value: "off", percentage_bps: 0)
    expect(tool_class { requires_flag :summaries }.new.call({}, actor: operator).dig("error", "message"))
      .to eq("threadSummaries is disabled")
  end

  it "takes any callable for for: and client:, and refuses a client that isn't one" do
    rule!(conditions: { "platforms" => [ "ios" ] })
    callable = Struct.new(:value) { def call(_actor) = value }
    gated = tool_class { requires_flag :summaries, for: callable.new({ account: Struct.new(:id).new(1) }), client: callable.new({ platform: "ios" }) }.new
    expect(gated.call({}, actor: operator)).to eq("ran" => 7)
    expect { tool_class { requires_flag :summaries, client: "ios" } }.to raise_error(ArgumentError, /client: must be/)
  end
end
