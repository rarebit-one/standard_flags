# Shared pieces for the Restore specs.
module RestoreHelpers
  # Stands in for standard_audit's audit_logs on MemoryStore: records each
  # write-path event's payload, as JSON, with the time it was published, and
  # answers AuditTrail#rule_states from them.
  class RecordingTrail
    attr_reader :rows

    def initialize
      @rows = []
      @subscriber = ActiveSupport::Notifications.subscribe(/\Astandard_flags\.(flag|cohort)\./) do |name, *, payload|
        @rows << [ Time.now, name, JSON.parse(JSON.generate(payload.except(:actor))) ]
      end
    end

    def stop
      ActiveSupport::Notifications.unsubscribe(@subscriber)
    end

    def rule_states(at)
      @rows.select { |time, name, _| time <= at && StandardFlags::AuditTrail::RULE_EVENTS.include?(name) }
           .each_with_object({}) { |(_, _, metadata), states| states[metadata["key"].to_sym] = metadata["after"] }
    end
  end

  # A time after everything so far and before anything after.
  def checkpoint
    sleep 0.01
    Time.now.tap { sleep 0.01 }
  end
end

RSpec.configure { |config| config.include RestoreHelpers }
