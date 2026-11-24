require "spec_helper"

RSpec.describe StandardFlags::Job do
  describe "client:" do
    include ActiveJob::TestHelper

    let(:performed) { [] }

    before do
      clear_enqueued_jobs
      define_flags do
        unit :account, from: ->(ctx) { ctx.actor(:account) }
        flag :new_importer, owner: "data", remove_by: "2027-01-01", final: true, unit: :account
      end
      with_rule(:new_importer, percentage: 10_000, fallthrough: false, platforms: %w[ios], versions: { ios: ">=2.0" })
    end

    def job_class(**options)
      log = performed
      Class.new(ActiveJob::Base) do
        include StandardFlags::Job

        define_singleton_method(:name) { "ClientProbeJob" }
        requires_flag(:new_importer, for: -> { { account: arguments.first } }, **options)
        define_method(:perform) { |*args| log << args.first }
      end
    end

    it "evaluates for a client returned by a lambda run in the job" do
      klass = job_class(client: -> { arguments.second })
      klass.perform_now("acct_1", { "platform" => "ios", "version" => "2.1.0" })
      klass.perform_now("acct_2", { "platform" => "ios", "version" => "1.9.0" })
      klass.perform_now("acct_3", nil)
      expect(performed).to eq([ "acct_1" ])
    end

    it "takes a client value" do
      job_class(client: StandardFlags::Client.new(platform: "ios", version: "3")).perform_now("acct_1")
      expect(performed).to eq([ "acct_1" ])
    end
  end
end
