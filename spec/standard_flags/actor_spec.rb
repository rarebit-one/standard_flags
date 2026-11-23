require "spec_helper"

RSpec.describe StandardFlags::Actor do
  it "names a system actor and compares by name" do
    actor = described_class.system("rake")
    expect([ actor.to_s, actor.inspect, actor.system? ]).to eq([ "system:rake", "system:rake", true ])
    expect(actor).to eq(described_class.system("rake")).and(eql(described_class.new("rake")))
    expect({ actor => 1 }[described_class.system("rake")]).to eq(1)
    expect(actor).not_to eq(described_class.system("guard"))
  end

  it "needs a name" do
    expect { described_class.system(" ") }.to raise_error(ArgumentError, /needs a name/)
  end

  it "labels actors by class and id only" do
    user = Struct.new(:id, :email).new(7, "someone@example.com")
    expect(described_class.label(described_class.system)).to eq("system:system")
    expect(described_class.label(user)).to end_with(":7")
    expect(described_class.label(user)).not_to include(user.email)
    expect(described_class.label(Object.new)).to eq("Object")
    expect(described_class.label(nil)).to be_nil
  end
end
