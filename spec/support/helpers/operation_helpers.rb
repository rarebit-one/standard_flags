require_relative "runtime_helpers"


# Shared pieces for the write-path specs.
module OperationHelpers
  Ops = StandardFlags::Operations
  User = Struct.new(:id)

  # Distinctive unit keys, so a spec can prove none of them leaks into a
  # result, an event or a report.
  SECRET_KEYS = %w[acct-7731 acct-7732 +6591234567].freeze

  REGISTRY = proc do
    instance_eval(&RuntimeHelpers::REGISTRY)
    flag :legacy_ramp, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                       bucketing: { version: 1, salt: "legacy-salt" }
    tombstone :old_banner, removed: "2026-01-01"
  end

  ATTACHED = ->(store) { store.put_rule(:new_checkout, status: :running, cohorts: { staff: true }) }
  MEMBER = lambda do |store|
    store.put_rule(:new_checkout, status: :running)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "acct-7731", value: true)
  end
  DRAFT = ->(store) { store.put_rule(:new_checkout, status: :draft, fallthrough_value: true) }
  RUNNING = ->(store) { store.put_rule(:new_checkout, status: :running) }

  # One case per operation (two for the membership ones): [name,
  # operation, target, args, setup, expected event], for contract_spec.
  CONTRACT_CASES = [
    [ "Start", Ops::Start, :new_checkout, {}, DRAFT, "standard_flags.flag.started" ],
    [ "Pause", Ops::Pause, :new_checkout, {}, RUNNING, "standard_flags.flag.paused" ],
    [ "Stop", Ops::Stop, :new_checkout, { serve: true }, nil, "standard_flags.flag.stopped" ],
    [ "Ramp", Ops::Ramp, :new_checkout, { bps: 500 }, nil, "standard_flags.flag.ramped" ],
    [ "SetVariants", Ops::SetVariants, :home_hero, { weights: { "control" => 5_000, "savings" => 5_000 } }, nil, "standard_flags.flag.variants_set" ],
    [ "SetValue", Ops::SetValue, :strict_gates, { value: :sensor }, nil, "standard_flags.flag.value_set" ],
    [ "SetConditions", Ops::SetConditions, :new_checkout, { platforms: %w[ios], versions: { ios: ">= 2.0" } }, nil, "standard_flags.flag.conditions_set" ],
    [ "AddMembers on a rule", Ops::AddMembers, :new_checkout, { keys: [ RuntimeHelpers::Account.new("acct-7731"), "acct-7732" ] }, nil, "standard_flags.flag.members_added" ],
    [ "RemoveMembers on a rule", Ops::RemoveMembers, :new_checkout, { keys: [ "acct-7731" ] }, MEMBER, "standard_flags.flag.members_removed" ],
    [ "AttachCohort", Ops::AttachCohort, :new_checkout, { cohort: "staff", value: true }, nil, "standard_flags.cohort.attached" ],
    [ "DetachCohort", Ops::DetachCohort, :new_checkout, { cohort: "staff" }, ATTACHED, "standard_flags.cohort.detached" ],
    [ "AddMembers on a cohort", Ops::AddMembers, "cohort:staff", { keys: [ "acct-7732" ] }, nil, "standard_flags.cohort.members_added" ],
    [ "RemoveMembers on a cohort", Ops::RemoveMembers, "cohort:staff", { keys: [ "acct-7731" ] }, nil, "standard_flags.cohort.members_removed" ],
    [ "CreateCohort", Ops::CreateCohort, "beta", { unit: :account, name: "Beta" }, nil, "standard_flags.cohort.created" ],
    [ "ArchiveCohort", Ops::ArchiveCohort, "staff", {}, nil, "standard_flags.cohort.archived" ]
  ].freeze

  def system_actor
    StandardFlags::Actor.system("spec")
  end

  # Runs an operation as the system actor with a reason, unless given.
  def op(klass, target, **args)
    klass.call(target, actor: system_actor, reason: "spec", **args)
  end

  def op!(klass, target, **args)
    op(klass, target, **args).tap { |result| expect(result).to be_success, -> { result.inspect } }
  end

  # [name, payload] for every write-path and change event in the block.
  def events_during
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Astandard_flags\.|\Achange\.standard_flags\z/) do |name, *, payload|
      events << [ name, payload ]
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def expect_no_unit_keys(*things)
    text = things.map(&:inspect).join("\n")
    SECRET_KEYS.each { |key| expect(text).not_to include(key) }
  end
end

RSpec.configure { |config| config.include OperationHelpers }
