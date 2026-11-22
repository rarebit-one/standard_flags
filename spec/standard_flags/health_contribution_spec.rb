require "spec_helper"

RSpec.describe StandardFlags::HealthContribution do
  # Stands in for standard_health's Contributions::Facade, recording calls and
  # running the env block on a recording DSL.
  let(:facade) do
    Class.new do
      attr_reader :checks, :env_vars

      def initialize
        @checks = []
        @env_vars = {}
      end

      def contribute_check(name, klass, **options)
        @checks << [ name, klass, options ]
      end

      def contribute_env_vars(contributor, &block)
        dsl = Class.new do
          attr_reader :entries

          def initialize = @entries = []
          def forbidden(name, **options) = @entries << [ :forbidden, name, options ]
        end.new
        dsl.instance_eval(&block)
        @env_vars[contributor] = dsl.entries
      end
    end.new
  end

  after { described_class.reset! }

  it "registers the hook at require time" do
    hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:standard_health]
    expect(hooks.map(&:first)).to include(described_class::HOOK)
  end

  it "contributes the check and the pins of forbidden_in flags when the hook runs" do
    define_flags do
      flag :demo_data, owner: "web", remove_by: "2099-01-01", final: false, forbidden_in: %i[production], env: "ACME_DEMO"
      flag :new_checkout, owner: "payments", remove_by: "2099-01-01", final: true
    end
    described_class::HOOK.call(facade)

    expect(facade.checks).to eq([ [ :standard_flags, "StandardFlags::HealthCheck", { critical: false } ] ])
    entries = facade.env_vars.fetch("standard_flags")
    expect(entries.map { |level, name, options| [ level, name, options[:in] ] })
      .to eq([ [ :forbidden, :STANDARD_FLAGS_DEMO_DATA, %w[production] ], [ :forbidden, :ACME_DEMO, %w[production] ] ])
    expect(entries.first.last[:description]).to eq("Pins :demo_data, which is forbidden_in: these environments")
  end

  it "applies only when the pin turns the flag on" do
    define_flags { flag :demo_data, owner: "web", remove_by: "2099-01-01", final: false, forbidden_in: :production }
    described_class::HOOK.call(facade)
    condition = facade.env_vars.fetch("standard_flags").first.last[:if]
    set_env("STANDARD_FLAGS_DEMO_DATA" => "off")
    expect(condition.call).to be(false)
    set_env("STANDARD_FLAGS_DEMO_DATA" => "on")
    expect(condition.call).to be(true)
  end

  it "re-contributes when the registry is redefined, and only after the hook ran" do
    define_flags { flag :a, owner: "o", remove_by: "2099-01-01", final: false, forbidden_in: :production }
    expect(facade.env_vars).to be_empty
    described_class::HOOK.call(facade)
    define_flags { flag :b, owner: "o", remove_by: "2099-01-01", final: false, forbidden_in: :staging }
    expect(facade.env_vars.fetch("standard_flags").map { |e| e[1] }).to eq([ :STANDARD_FLAGS_B ])
  end

  it "never lets a failed contribution break define" do
    described_class::HOOK.call(facade)
    allow(facade).to receive(:contribute_env_vars).and_raise(ArgumentError, "bad")
    expect { define_flags { flag :a, owner: "o", remove_by: "2099-01-01", final: true } }
      .to output(/standard_health env contribution failed: ArgumentError: bad/).to_stderr
  end
end
