require "spec_helper"

RSpec.describe "the ActiveRecord store on Postgres", :db, registry: RuntimeHelpers::REGISTRY do
  let(:models) { StandardFlags::Runtime::Models }
  let(:time) { [ 0.0 ] }

  before do
    require "standard_flags/runtime/active_record_store"
    StandardFlags.config.runtime_rules = true
    StandardFlags::Runtime.clock = -> { time.first }
  end

  def rule!(key, **attributes)
    models::Rule.create!(key: key.to_s, salt: key.to_s, status: "running", **attributes)
  end

  def bump!
    models::State.update_all("revision = revision + 1")
  end

  def member!(owner, unit_key, value: "on", unit: "account", **attributes)
    owner_column = owner.is_a?(models::Rule) ? :rule_id : :cohort_id
    models::Membership.create!(owner_column => owner.id, unit: unit, unit_key: unit_key.to_s, value: value, **attributes)
  end

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  it "is the default store when runtime rules are on" do
    expect(StandardFlags::Runtime.store).to be_a(StandardFlags::Runtime::ActiveRecordStore)
    expect(StandardFlags::Runtime.store).to be_ready
  end

  it "evaluates stored rules, cohorts and memberships" do
    staff = models::Cohort.create!(key: "staff", unit: "account", member_count: 1)
    gates = rule!(:strict_gates, cohorts: [ { cohort: "staff", value: "on" } ], fallthrough_value: "sensor")
    checkout = rule!(:new_checkout, member_count: 2, variant_weights: {}, conditions: { platforms: [ "ios" ] })
    member!(staff, 7)
    member!(checkout, 7, value: "off")
    member!(checkout, 8, value: "on", removed_at: Time.now)
    member!(checkout, 9, value: "on", expires_at: Time.now - 60)
    member!(gates, 9, value: "on", removed_at: Time.now)
    bump!

    expect(StandardFlags.evaluate(:strict_gates, for: for_account(7))).to have_attributes(value: :on, rule_id: "cohort:staff")
    expect(StandardFlags.evaluate(:strict_gates, for: for_account(9))).to have_attributes(value: :sensor, rule_id: "fallthrough")
    expect(StandardFlags.evaluate(:new_checkout, for: for_account(7))).to have_attributes(value: false, rule_id: "deny")
    [ 8, 9 ].each { |id| expect(StandardFlags.evaluate(:new_checkout, for: for_account(id)).reason).to eq("DEFAULT") }
  end

  it "reloads when the revision moves" do
    rule = rule!(:new_checkout, fallthrough_value: "on")
    bump!
    expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
    rule.update!(status: "paused")
    bump!
    expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
    time[0] += 5
    expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(false)
  end

  describe "query counts" do
    it "runs no query per evaluation once rules are cached and no rule has members" do
      rule!(:new_checkout, percentage_bps: 5_000)
      StandardFlags.evaluate(:global_banner)

      queries = DatabaseHelpers.queries do
        unit_of_work { (1..25).each { |id| StandardFlags.evaluate(:new_checkout, for: for_account(id)) } }
        unit_of_work { StandardFlags.snapshot(for: for_account(1)) }
      end
      expect(queries).to eq([])
    end

    it "runs one membership query per unit per unit of work" do
      staff = models::Cohort.create!(key: "staff", unit: "account", member_count: 1)
      checkout = rule!(:new_checkout, member_count: 1)
      rule!(:strict_gates, cohorts: [ { cohort: "staff", value: "on" } ])
      member!(checkout, 1)
      member!(staff, 1)
      StandardFlags.evaluate(:global_banner)

      queries = DatabaseHelpers.queries do
        unit_of_work do
          3.times { %i[new_checkout strict_gates home_hero].each { |key| StandardFlags.evaluate(key, for: for_account(1)) } }
        end
      end
      expect(queries.size).to eq(1)
      expect(queries.first).to include("standard_flags_memberships", '"removed_at" IS NULL')
    end

    it "runs one query for a preloaded list" do
      checkout = rule!(:new_checkout, member_count: 1)
      member!(checkout, 4)
      accounts = (1..30).map { |id| account(id) }
      StandardFlags.evaluate(:global_banner)

      values = nil
      queries = DatabaseHelpers.queries do
        unit_of_work do
          StandardFlags.preload(:account, accounts)
          values = accounts.map { |a| StandardFlags.on?(:new_checkout, for: { account: a }) }
        end
      end
      expect(queries.size).to eq(1)
      expect(values.each_index.select { |i| values[i] }).to eq([ 3 ])
    end

    it "runs one revision check per interval" do
      rule!(:new_checkout, fallthrough_value: "on")
      queries = DatabaseHelpers.queries do
        12.times do
          unit_of_work { StandardFlags.evaluate(:new_checkout, for: for_account(1)) }
          time[0] += 1
        end
      end
      revision_checks = queries.grep(/standard_flags_state/)
      expect(revision_checks.size).to eq(3) # t=0 (then load), t=5, t=10
      expect(queries.size).to eq(5) # plus the rule and cohort loads at t=0
    end
  end

  describe "failures" do
    it "keeps a failed read from aborting the host's transaction" do
      checkout = rule!(:new_checkout, member_count: 1)
      member!(checkout, 1)
      StandardFlags.evaluate(:global_banner)
      connection = ActiveRecord::Base.connection

      ActiveRecord::Base.transaction do
        connection.execute("ALTER TABLE standard_flags_memberships RENAME TO standard_flags_memberships_moved")
        errors = collect_errors do
          expect(StandardFlags.evaluate(:new_checkout, for: for_account(1))).to have_attributes(reason: "ERROR", error_code: "GENERAL")
        end
        expect(errors.errors_of(StandardFlags::Runtime::StoreError).map(&:message))
          .to eq([ "membership lookup failed: ActiveRecord::StatementInvalid" ])
        expect(errors.errors_of(StandardFlags::Runtime::StoreError).first.cause).to be_nil
        expect(connection.select_value("SELECT 1")).to eq(1)
        raise ActiveRecord::Rollback
      end
    end

    it "fails the health check when the tables are missing, and serves code defaults" do
      require "standard_health/check"
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("DROP TABLE standard_flags_state")
        expect(StandardFlags::Runtime.store).not_to be_ready
        expect(StandardFlags.evaluate(:new_checkout, for: for_account(1))).to have_attributes(reason: "DEFAULT")
        expect(StandardFlags::HealthCheck.new.run).to include(status: :fail, error_class: "StandardFlags::RuntimeUnavailable")
        raise ActiveRecord::Rollback
      end
    end
  end

  describe "readiness" do
    it "warns rather than fails when the database can't be reached" do
      require "standard_health/check"
      allow(models::Record).to receive(:with_connection).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect(StandardFlags::Runtime.readiness).to eq("ActiveRecord::ConnectionNotEstablished")
      expect(StandardFlags::HealthCheck.new.run).to include(status: :ok)
    end

    it "reads an undefined-table error from the readiness check as missing tables" do
      undefined = begin
        begin
          raise PG::UndefinedTable, "relation does not exist"
        rescue PG::UndefinedTable
          raise ActiveRecord::StatementInvalid, "undefined table"
        end
      rescue ActiveRecord::StatementInvalid => e
        e
      end
      allow(models::Record).to receive(:with_connection).and_raise(undefined)
      expect(StandardFlags::Runtime.store.ready?).to be(false)
      expect(StandardFlags::Runtime.readiness).to be(false)
    end
  end

  describe "privacy" do
    it "adds unit_key to ActiveRecord::Base's filter, so SQL logs never show a unit key" do
      require "active_record/log_subscriber"
      checkout = rule!(:new_checkout, member_count: 1)
      member!(checkout, 5_550_001)
      bump!
      StandardFlags.evaluate(:global_banner)
      expect(ActiveRecord::Base.filter_attributes.map(&:to_s)).to include("unit_key")

      log = StringIO.new
      previous = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(log).tap { |logger| logger.level = :debug }
      unit_of_work { expect(StandardFlags.on?(:new_checkout, for: for_account(5_550_001))).to be(true) }
      expect(log.string).to include("standard_flags_memberships")
      expect(log.string).not_to include("5550001")
    ensure
      ActiveRecord::Base.logger = previous
    end

    it "adds the filter once, through the engine's boot" do
      StandardFlags::Runtime.boot!
      StandardFlags::Runtime.boot!
      expect(ActiveRecord::Base.filter_attributes.count { |f| f.to_s == "unit_key" }).to eq(1)
    end

    it "warns when prepared statements are off, since values are then inlined into the SQL" do
      expect(StandardFlags::Runtime.store.warnings).to eq([])
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        "test", "primary", { adapter: "postgresql", prepared_statements: "false" }
      )
      allow(models::Record).to receive(:connection_db_config).and_return(config)
      expect(StandardFlags::Diagnostics.warnings(StandardFlags::Diagnostics.report))
        .to include(a_string_starting_with("prepared statements are off, so unit keys are inlined"))
    end
  end

  describe "the schema" do
    it "enforces statuses, percentages and exactly one owner per membership" do
      expect { rule!(:new_checkout, status: "live") }.to raise_error(ActiveRecord::StatementInvalid, /standard_flags_rules_status/)
      expect { rule!(:new_checkout, percentage_bps: 10_001) }.to raise_error(ActiveRecord::StatementInvalid, /percentage_bps/)
      expect { models::Membership.create!(unit: "account", unit_key: "1", value: "on") }
        .to raise_error(ActiveRecord::StatementInvalid, /one_owner/)
    end

    it "allows one live membership per owner and unit key, keeping removed ones" do
      checkout = rule!(:new_checkout)
      member!(checkout, 1, removed_at: Time.now)
      member!(checkout, 1)
      expect { member!(checkout, 1) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "seeds one state row and defaults the rule columns" do
      expect(models::State.pluck(:revision)).to eq([ 0 ])
      expect(models::Rule.create!(key: "x", salt: "s"))
        .to have_attributes(status: "draft", hash_version: 2, variant_weights: {}, conditions: {}, cohorts: [], member_count: 0)
    end

    it "keeps unit keys out of inspect" do
      expect(member!(rule!(:new_checkout), "+6591234567").inspect).not_to include("9123")
    end

    it "is accepted by StrongMigrations, which is active" do
      unsafe = Class.new(ActiveRecord::Migration[8.1]) do
        def change = add_index(:standard_flags_rules, :salt)
      end
      expect { unsafe.migrate(:up) }.to raise_error(StrongMigrations::UnsafeMigration)
    end

    it "builds with UUID keys when the app generates them" do
      generators = Rails.application.config.generators
      previous = generators.options[:active_record].dup
      generators.options[:active_record][:primary_key_type] = :uuid
      DatabaseHelpers.run_generated_migration(:down)
      DatabaseHelpers.run_generated_migration(:up)
      models.constants.each { |name| models.const_get(name).reset_column_information }

      checkout = rule!(:new_checkout, member_count: 1)
      member!(checkout, 1)
      expect(checkout.id).to match(/\A\h{8}-\h{4}-/)
      expect(StandardFlags.evaluate(:new_checkout, for: for_account(1)).rule_id).to eq("allow")
    ensure
      generators.options[:active_record] = previous
      DatabaseHelpers.run_generated_migration(:down)
      DatabaseHelpers.run_generated_migration(:up)
      models.constants.each { |name| models.const_get(name).reset_column_information }
    end
  end

  describe "Bucket.sql_v2" do
    it "matches Bucket.v2 on Postgres for every v2 vector" do
      vectors = ConformanceRegistry.load(File.expand_path("../fixtures/conformance/bucket_vectors.json", __dir__))
                                   .fetch("vectors").select { |v| v["version"] == 2 }
      expect(vectors.size).to be > 10
      connection = ActiveRecord::Base.connection
      vectors.each do |vector|
        sql = StandardFlags::Bucket.sql_v2(column: "unit_key", decision: vector.fetch("decision"))
        query = ActiveRecord::Base.sanitize_sql([ "SELECT #{sql} FROM (SELECT :unit::text AS unit_key) AS units",
                                                  { salt: vector.fetch("salt"), unit: vector["unit_key"] } ])
        expect(connection.select_value(query)).to eq(vector["bucket"]), vector.inspect
        expected = StandardFlags::Bucket.v2(vector.fetch("decision"), vector.fetch("salt"), vector["unit_key"])
        expect(connection.select_value(query)).to eq(expected)
      end
    end
  end
end
