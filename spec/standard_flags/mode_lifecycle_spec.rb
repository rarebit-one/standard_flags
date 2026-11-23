require "spec_helper"
require "standard_health"

# Modes may declare a lifecycle like flags: `remove_by:` with the `final:`
# value they settle on, or `permanent: true`. Undeclared, they behave as
# before: no lifecycle, never stale.
RSpec.describe StandardFlags::Definition, "#remove_by on modes" do
  def build(**attributes)
    StandardFlags::Definition.new(:mode, :billing_cutover, { owner: "billing", preset: :cutover }.merge(attributes))
  end

  describe "declaration" do
    it "takes remove_by: with a final: from the mode's values" do
      mode = build(remove_by: "2027-01-01", final: "all")
      expect([ mode.remove_by, mode.final, mode.permanent? ]).to eq([ Date.new(2027, 1, 1), :all, false ])
      expect(mode.stale?(Date.new(2027, 1, 2))).to be(true)
    end

    it "rejects a final: outside the mode's values" do
      expect { build(remove_by: "2027-01-01", final: :on) }
        .to raise_error(StandardFlags::DefinitionError, /final: :on is not one of \[:off, :allowlist, :all\]/)
    end

    it "needs remove_by: and final: together" do
      expect { build(remove_by: "2027-01-01") }.to raise_error(StandardFlags::DefinitionError, /missing final:/)
      expect { build(final: :all) }.to raise_error(StandardFlags::DefinitionError, /has final: but is missing remove_by:/)
    end

    it "takes permanent: true, with the same rules as a permanent flag" do
      expect(build(permanent: true)).to be_permanent
      expect(build(permanent: true).stale?(Date.new(2999, 1, 1))).to be(false)
      expect { build(permanent: true, remove_by: "2027-01-01", final: :all) }
        .to raise_error(StandardFlags::DefinitionError, /permanent: and cannot have remove_by:/)
      expect { build(permanent: true, final: :all) }
        .to raise_error(StandardFlags::DefinitionError, /permanent: and cannot have final:/)
      expect { build(permanent: "yes") }.to raise_error(StandardFlags::DefinitionError, /permanent: must be true or false/)
    end

    it "still needs no lifecycle at all" do
      mode = build
      expect([ mode.remove_by, mode.final, mode.permanent?, mode.stale?(Date.new(2999, 1, 1)) ]).to eq([ nil, nil, false, false ])
    end
  end

  describe "tooling and diagnostics" do
    before do
      define_flags do
        env_resolver -> { "production" }
        flag :old_banner, owner: "growth", remove_by: "2020-06-01", final: false
        mode :billing_cutover, owner: "billing", preset: :cutover, remove_by: "2020-01-01", final: :all
        mode :strict_gates, owner: "platform", preset: :sensor, permanent: true
        mode :review_flow, owner: "platform", preset: :shadow
      end
    end

    let(:today) { Date.new(2026, 1, 1) }

    it "lists a stale mode in flags:stale with its final value, never a permanent one" do
      expect(StandardFlags::Tooling::Stale.new(today: today).render).to eq(<<~TEXT.chomp)
        billing_cutover (mode, owner: billing) was due for removal on 2020-01-01, final: :all
        old_banner (flag, owner: growth) was due for removal on 2020-06-01, final: false
      TEXT
    end

    it "shows a mode's remove_by or permanent in flags:list" do
      lines = StandardFlags::Tooling::List.new.render.lines.map(&:split)
      expect(lines).to include(%w[billing_cutover mode off DEFAULT - 2020-01-01],
                               %w[strict_gates mode off DEFAULT - permanent],
                               %w[review_flow mode off DEFAULT - -])
    end

    it "says whether each mode is permanent in the manifest" do
      flags = JSON.parse(StandardFlags::Tooling::Manifest.new.render)["flags"].to_h { |f| [ f["key"], f["permanent"] ] }
      expect(flags).to eq("billing_cutover" => false, "old_banner" => false, "review_flow" => false, "strict_gates" => true)
    end

    it "reports a stale mode in Diagnostics and as a health check warning" do
      report = StandardFlags::Diagnostics.report(today: today)
      rows = report[:flags].to_h { |f| [ f[:key], f.values_at(:remove_by, :permanent, :stale) ] }

      expect(rows).to include(billing_cutover: [ "2020-01-01", false, true ], strict_gates: [ nil, true, false ],
                              review_flow: [ nil, false, false ])
      expect(report[:stale]).to contain_exactly({ flag: :billing_cutover, remove_by: "2020-01-01" },
                                                { flag: :old_banner, remove_by: "2020-06-01" })
      expect(StandardFlags::HealthCheck.new.run[:warnings]).to include(":billing_cutover is past remove_by 2020-01-01")
    end
  end
end
