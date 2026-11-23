require "spec_helper"

RSpec.describe StandardFlags::Result do
  it "carries a value on success" do
    result = described_class.success(revision: 3)
    expect(result).to have_attributes(success?: true, failure?: false, value: { revision: 3 }, errors: [], code: nil)
    expect(result.inspect).to eq("#<StandardFlags::Result success>")
  end

  it "carries a code and messages on failure" do
    result = described_class.failure(:invalid, "bps must be an Integer")
    expect(result).to have_attributes(success?: false, failure?: true, code: :invalid, errors: [ "bps must be an Integer" ])
    expect(result.inspect).to eq('#<StandardFlags::Result failure invalid ["bps must be an Integer"]>')
    expect(result).to be_frozen
  end
end
