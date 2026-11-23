require "spec_helper"

RSpec.describe StandardFlags::Notifiers::Logger, "#call" do
  subject(:logger) { described_class.new(Logger.new(nil)) }

  it "describes each runtime event in one line" do
    {
      "runtime_stale" => [ { error_class: "PG::ConnectionBad", loaded: true, revision: 4, age: 12.5 },
                           "runtime rules could not refresh (PG::ConnectionBad); serving revision 4 (12.5s old)" ],
      "runtime_refresh" => [ { revision: 5, rules: 2 }, "loaded runtime rules at revision 5 (2 rules)" ],
      "rule_invalid" => [ { key: :x, error: "has \"maybe\" in fallthrough_value" },
                          "runtime rule for :x has \"maybe\" in fallthrough_value; serving its fail value" ],
      "targeting_key_missing" => [ { key: :x, unit: :account },
                                   "runtime rule for :x needs a :account key and the context has none" ]
    }.each do |event, (payload, message)|
      expect(logger.call("#{event}.standard_flags", payload)).to eq(message)
    end
  end

  it "says when rules never loaded" do
    expect(logger.call("runtime_stale.standard_flags", { error_class: "X", loaded: false }))
      .to eq("runtime rules could not refresh (X); serving code defaults (never loaded)")
  end
end
