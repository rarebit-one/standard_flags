require "spec_helper"

RSpec.describe StandardFlags::Registry do
  it "replaces the registry on each define" do
    define_flags { kill_switch :first_switch, owner: "x" }
    define_flags { kill_switch :second_switch, owner: "x" }

    expect(StandardFlags.registry.keys).to eq([ :second_switch ])
  end

  it "defaults the environment to Rails.env" do
    define_flags { kill_switch :ai_assistant, owner: "x" }
    expect(StandardFlags.registry.current_env).to eq("test")
  end

  it "uses a declared env_resolver" do
    define_flags { env_resolver -> { :staging } }
    expect(StandardFlags.registry.current_env).to eq("staging")
  end

  it "accepts a block env_resolver" do
    define_flags { env_resolver { "sandbox" } }
    expect(StandardFlags.registry.current_env).to eq("sandbox")
  end

  it "records units" do
    define_flags { unit :account, from: ->(ctx) { ctx.account } }
    expect(StandardFlags.registry.units.keys).to eq([ :account ])
  end

  it "lists exposed flags per audience in wire-name order" do
    define_flags do
      kill_switch :zeta, owner: "x", expose: { web: :alpha }
      kill_switch :alpha, owner: "x", expose: { web: :zeta, mobile: :alpha }
      kill_switch :hidden, owner: "x"
    end

    expect(StandardFlags.registry.exposed(:web).map(&:key)).to eq(%i[zeta alpha])
    expect(StandardFlags.registry.audiences).to eq(%i[mobile web])
  end

  describe "define-time validation" do
    it "refuses to reuse a tombstoned key, whichever comes first" do
      expect do
        define_flags do
          tombstone :manual_entry, removed: "2026-12-01"
          kill_switch :manual_entry, owner: "x"
        end
      end.to raise_error(StandardFlags::DefinitionError, /removed on 2026-12-01; keys are never reused/)

      expect do
        define_flags do
          kill_switch :manual_entry, owner: "x"
          tombstone :manual_entry, removed: "2026-12-01"
        end
      end.to raise_error(StandardFlags::DefinitionError, /never reused/)
    end

    it "rejects a duplicate key" do
      expect { define_flags { 2.times { kill_switch :ai_assistant, owner: "x" } } }
        .to raise_error(StandardFlags::DefinitionError, /declared twice/)
    end

    it "rejects duplicate wire names within one audience" do
      expect do
        define_flags do
          kill_switch :chat_v1, owner: "x", expose: { mobile: :chat }
          kill_switch :chat_v2, owner: "x", expose: { mobile: :chat }
        end
      end.to raise_error(StandardFlags::DefinitionError, /"chat" for audience :mobile is used by both/)
    end

    it "allows the same wire name in different audiences" do
      define_flags do
        kill_switch :chat_web, owner: "x", expose: { web: :chat }
        kill_switch :chat_mobile, owner: "x", expose: { mobile: :chat }
      end
      expect(StandardFlags.registry.keys.size).to eq(2)
    end

    it "rejects an undeclared unit" do
      expect { define_flags { kill_switch :ai_assistant, owner: "x", unit: :account } }
        .to raise_error(StandardFlags::DefinitionError, /undeclared unit :account/)
    end

    it "rejects a malformed unit, tombstone or env_resolver" do
      expect { define_flags { unit :account } }.to raise_error(StandardFlags::DefinitionError, /from:/)
      expect { define_flags { 2.times { unit :account, from: ->(c) { c } } } }.to raise_error(StandardFlags::DefinitionError, /twice/)
      expect { define_flags { tombstone :old, removed: "soon" } }.to raise_error(StandardFlags::DefinitionError, /YYYY-MM-DD/)
      expect { define_flags { 2.times { tombstone :old, removed: "2026-01-01" } } }.to raise_error(StandardFlags::DefinitionError, /twice/)
      expect { define_flags { env_resolver "production" } }.to raise_error(StandardFlags::DefinitionError, /callable/)
    end

    it "keeps the previous registry when a definition fails" do
      define_flags { kill_switch :ai_assistant, owner: "x" }
      expect { define_flags { kill_switch :broken } }.to raise_error(StandardFlags::DefinitionError)
      expect(StandardFlags.registry.keys).to eq([ :ai_assistant ])
    end
  end
end
