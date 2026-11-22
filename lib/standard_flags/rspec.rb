require "standard_flags"

# RSpec support for host apps. In `spec/rails_helper.rb`:
#
#   require "standard_flags/rspec"
#
# Then, in any example:
#
#   with_flag(:new_checkout, true) { ... }       # for the block
#   with_flag(:new_checkout, true)               # for the rest of the example
#   with_mode(:strict_gates, :sensor) { ... }
#   with_variant(:home_hero, "treatment") { ... }
#
#   it "shows the new checkout", flags: { new_checkout: true } do ... end
#
# Runtime rules, held in an in-memory store for the example (no database,
# whatever the app's own runtime configuration):
#
#   with_rule(:new_checkout, percentage: 5_000)              # running, 50%
#   with_rule(:new_checkout, status: :paused)
#   with_members(:new_checkout, account, value: false)       # a deny
#   with_cohort(:staff, unit: :account, members: [ a, b ])
#   with_rule(:new_checkout, cohorts: { staff: true })
#
# Overrides are the first evaluation layer, so they beat `forbidden_in:`
# guards, ENV pins and defaults: prove a guard with a real ENV pin, not an
# override. Runtime rules sit below overrides and pins, so `with_flag` beats
# `with_rule`. Unknown keys and values outside the declaration raise, unknown
# keys raise on read (strict mode), and everything resets after each example.
module StandardFlags
  module TestHelpers
    def with_flag(key, value, &)
      apply_override(key, value, Definition::BOOLEAN_KINDS, &)
    end

    def with_mode(key, value, &)
      apply_override(key, value, :mode, &)
    end

    def with_variant(key, value, &)
      apply_override(key, value, :experiment, &)
    end

    # See StandardFlags::Testing.rule for the options.
    def with_rule(key, **options)
      StandardFlags::Testing.rule(key, **options)
    end

    def with_members(key, units, value: true, expires_at: nil)
      StandardFlags::Testing.members(key, units, value: value, expires_at: expires_at)
    end

    def with_cohort(key, unit:, members: [], expires_at: nil, archived: false)
      StandardFlags::Testing.cohort(key, unit: unit, members: members, expires_at: expires_at, archived: archived)
    end

    private

    def apply_override(key, value, kind, &block)
      return StandardFlags::Testing.with({ key => value }, kind: kind, &block) if block

      StandardFlags::Testing.override(key, value, kind: kind)
    end
  end
end

StandardFlags::Testing.activate!
StandardFlags.config.strict = true

RSpec.configure do |config|
  config.include StandardFlags::TestHelpers

  config.before do |example|
    StandardFlags::Testing.reset!
    Array(example.metadata[:flags]).each { |key, value| StandardFlags::Testing.override(key, value) }
  end

  config.after do
    StandardFlags::Testing.reset!
  end
end
