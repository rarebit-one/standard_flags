require "spec_helper"

# Every operation, against the in-memory store: success, a pinned flag, a
# stale expected_revision, an unauthorised actor, and no unit key in what it
# returns or publishes.
RSpec.describe StandardFlags::Operations, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    store.put_cohort(:staff, unit: :account)
    store.add_member(cohort: :staff, unit: :account, unit_key: "acct-7731", value: "on")
  end

  OperationHelpers::CONTRACT_CASES.each do |name, operation, target, args, setup, event|
    flag_target = target.is_a?(Symbol)

    describe name do
      before { setup&.call(store) }

      it "succeeds, bumps the revision once, and publishes #{event}" do
        revision = store.revision
        result = nil
        events = events_during { result = operation.call(target, actor: system_actor, reason: "contract", **args) }

        expect(result).to be_success, -> { result.inspect }
        expect([ result.value[:store_revision], store.revision ]).to eq([ revision + 1, revision + 1 ])
        # `revision` is what expected_revision is checked against.
        checked = target.is_a?(Symbol) ? store.rule(target).lock_version : store.revision
        expect(result.value[:revision]).to eq(checked)
        expect(events.map(&:first)).to eq([ event, "change.standard_flags" ])
        expect(events.first.last).to include(actor: nil, actor_label: "system:spec", reason: "contract",
                                             revision: checked, store_revision: revision + 1)
          .and(have_key(:before)).and(have_key(:after))
      end

      it "publishes no unit key" do
        result = nil
        events = events_during { result = operation.call(target, actor: system_actor, reason: "contract", **args) }
        expect_no_unit_keys(result, result.value, events)
      end

      it "refuses an actor the policy doesn't allow, writing nothing" do
        revision = store.revision
        result = operation.call(target, actor: OperationHelpers::User.new(9), reason: "contract", **args)
        expect(result).to have_attributes(success?: false, code: :unauthorized)
        expect(result.errors.first).to include("OperationHelpers::User:9")
        expect(store.revision).to eq(revision)
      end

      it "refuses a stale expected_revision, writing nothing" do
        revision = store.revision
        result = operation.call(target, actor: system_actor, reason: "contract", expected_revision: 41, **args)
        expect(result).to have_attributes(success?: false, code: :stale_revision)
        expect(store.revision).to eq(revision)
      end

      if flag_target
        it "refuses a flag an ENV pin decides, naming the variable and not its value" do
          var = "STANDARD_FLAGS_#{target.to_s.upcase}"
          pinned = { new_checkout: "true", home_hero: "privacy", strict_gates: "sensor" }.fetch(target)
          StandardFlags.config.env_source = { var => pinned }
          revision = store.revision

          result = operation.call(target, actor: system_actor, reason: "contract", **args)
          expect(result).to have_attributes(success?: false, code: :pinned_by_env)
          expect(result.errors.first).to include(var)
          expect(result.errors.first).not_to include(pinned)
          expect(store.revision).to eq(revision)
        end
      else
        it "has no pin to refuse (cohorts are not flags)" do
          StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "true" }
          expect(operation.call(target, actor: system_actor, reason: "contract", **args)).to be_success
        end
      end
    end
  end

  it "covers every operation" do
    expect(OperationHelpers::CONTRACT_CASES.map { |c| c[1] }.uniq).to match_array(described_class::ALL)
  end
end
