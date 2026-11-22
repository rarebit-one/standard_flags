# Shared pieces for the runtime-rule specs.
module RuntimeHelpers
  Account = Struct.new(:id)

  REGISTRY = proc do
    unit :account, from: ->(ctx) { ctx.account }
    unit :phone, from: ->(ctx) { ctx.phone }, key: ->(phone) { phone.to_s.delete("^0-9+") }
    flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account
    flag :phone_login, owner: "identity", remove_by: "2027-01-01", final: true, unit: :phone
    flag :global_banner, owner: "web", remove_by: "2027-01-01", final: true
    kill_switch :ai_assistant, owner: "assistant", unit: :account
    mode :strict_gates, owner: "platform", preset: :sensor, unit: :account
    experiment :home_hero, owner: "growth", variants: %w[control savings privacy], unit: :account
  end

  def account(id)
    Account.new(id)
  end

  def for_account(id, client: {})
    StandardFlags::Context.new(actors: { account: account(id) }, client: client)
  end

  # An account id whose v2 rollout bucket for `salt` is below (inside) or at
  # or above (outside) `bps`.
  def account_id(salt, bps, inside:, decision: "rollout")
    (1..10_000).find do |id|
      bucket = StandardFlags::Bucket.v2(decision, salt, id.to_s)
      inside ? bucket < bps : bucket >= bps
    end
  end
end

RSpec.configure { |config| config.include RuntimeHelpers }
