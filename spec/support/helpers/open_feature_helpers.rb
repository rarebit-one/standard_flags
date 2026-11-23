# Shared by the OpenFeature provider specs, which require
# "standard_flags/open_feature" themselves: nothing else in the suite loads
# the SDK.
module OpenFeatureHelpers
  REGISTRY = proc do
    unit :account, from: ->(ctx) { ctx.account }
    unit :organization, from: ->(ctx) { ctx.organization }
    unit :user, from: ->(ctx) { ctx.current_user }, key: ->(user) { user.phone }
    flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                        forbidden_in: %w[qa]
    kill_switch :ai_assistant, owner: "assistant", unit: :account, forbidden_in: %w[qa], default: { "qa" => false }
    compat :legacy_export, owner: "data", remove_by: "2027-01-01", unit: :account, forbidden_in: %w[qa],
                           default: { "qa" => false }
    mode :strict_gates, owner: "platform", preset: :sensor, unit: :account, forbidden_in: %w[qa]
    experiment :home_hero, owner: "growth", variants: %w[control savings privacy], unit: :account,
                           forbidden_in: %w[qa]
    flag :org_billing, owner: "billing", remove_by: "2027-01-01", final: true, unit: :organization
    flag :beta, owner: "growth", remove_by: "2027-01-01", final: true, unit: :user
    flag :global_banner, owner: "web", remove_by: "2027-01-01", final: true
    tombstone :old_banner, removed: "2026-01-01"
  end

  # One flag of each kind, the fetch that reads it, and a value other than
  # its off value for scenarios to serve.
  KINDS = {
    flag: { key: :new_checkout, fetch: :boolean, served: true },
    kill_switch: { key: :ai_assistant, fetch: :boolean, served: true },
    compat: { key: :legacy_export, fetch: :boolean, served: true },
    mode: { key: :strict_gates, fetch: :string, served: :on },
    experiment: { key: :home_hero, fetch: :string, served: "savings" }
  }.freeze

  # A caller default per fetch type, distinct from anything a flag serves.
  DEFAULTS = {
    boolean: false, string: "fallback", number: 42, integer: 7, float: 1.5, object: { "fallback" => true }
  }.freeze

  def provider
    @provider ||= StandardFlags::OpenFeature::Provider.new
  end

  def of_context(**fields)
    OpenFeature::SDK::EvaluationContext.new(**fields)
  end

  def fetch(type, key, context = nil, default: DEFAULTS.fetch(type))
    provider.public_send(:"fetch_#{type}_value", flag_key: key.to_s, default_value: default, evaluation_context: context)
  end

  # A mode's Symbol as the String the provider serves.
  def wire_value(value)
    value.is_a?(Symbol) ? value.to_s : value
  end

  # The provider's answer as a Hash, without flag_metadata's frozen copy.
  def resolution(details)
    details.to_h.except(:flag_metadata).merge(flag_metadata: details.flag_metadata.to_h)
  end
end
