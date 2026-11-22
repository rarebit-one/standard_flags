require "spec_helper"

# Fixed vectors live in spec/fixtures/conformance/bucket_vectors.json.
RSpec.describe StandardFlags::Bucket do
  it "implements v1 as SHA-256 of salt:unit_key" do
    expected = Digest::SHA256.hexdigest("new_checkout:acct_42")[0, 15].to_i(16) % 10_000
    expect(described_class.v1("new_checkout", "acct_42")).to eq(expected)
  end

  it "hashes rollout and variant decisions separately in v2" do
    rollout = described_class.v2(:rollout, "salt", "acct_42")
    variant = described_class.v2("variant", "salt", "acct_42")
    expect(rollout).to eq(Digest::SHA256.hexdigest("v2|rollout|salt|acct_42")[0, 15].to_i(16) % 10_000)
    expect(variant).not_to eq(rollout)
  end

  it "stays within 0...10_000" do
    buckets = (1..500).map { |i| described_class.v2(:rollout, "salt", "acct_#{i}") }
    expect(buckets).to all(be_between(0, 9_999))
  end

  it "returns nil for a missing unit key instead of a random bucket" do
    expect([ described_class.v1("s", nil), described_class.v2(:rollout, "s", ""), described_class.v2(:variant, "s", " ") ])
      .to eq([ nil, nil, nil ])
  end

  it "rejects unknown decisions" do
    expect { described_class.v2(:ramp, "s", "u") }.to raise_error(ArgumentError, /decision/)
    expect { described_class.sql_v2(column: "id", decision: "ramp") }.to raise_error(ArgumentError)
  end

  describe ".sql_v2" do
    it "builds the Postgres twin with a bound salt" do
      sql = described_class.sql_v2(column: "devices.id")
      expect(sql).to start_with("('x' || substr(encode(sha256(convert_to('v2|rollout|' || :salt || '|' || ")
      expect(sql).to include("devices.id::text").and(end_with("::bit(60)::bigint % 10000"))
    end

    it "maps a blank column to NULL like v2 maps it to nil" do
      expect(described_class.sql_v2(column: "id", decision: :variant))
        .to include("'v2|variant|'", "CASE WHEN btrim(id::text) = '' THEN NULL ELSE id::text END")
    end

    it "refuses anything but a plain column identifier" do
      expect { described_class.sql_v2(column: "id); DROP TABLE x; --") }.to raise_error(ArgumentError, /identifier/)
    end
  end
end
