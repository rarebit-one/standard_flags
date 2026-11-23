require "json"

module StandardFlags
  # Reads the write path's history back out of standard_audit's audit_logs
  # table, through its query API (StandardAudit::AuditLog). Used by Restore
  # (a rule's state at a past time) and the admin page (recent changes).
  # Only usable when the host has loaded standard_audit.
  class AuditTrail
    # The audit rows that carry a rule's full after-state.
    RULE_EVENTS = (Events::FLAG_EVENTS.values + Events::COHORT_EVENTS.values_at(:attached, :detached)).freeze

    def self.available?
      defined?(::StandardAudit::AuditLog) ? true : false
    end

    def initialize(log = ::StandardAudit::AuditLog)
      @log = log
    end

    # `{ key Symbol => after-state Hash (String keys) }` for every rule with
    # an audit row at or before `at`: the after-state of the row with the
    # highest revision (lock_version), so rows that share a timestamp still
    # order correctly.
    def rule_states(at)
      rows = @log.where(event_type: RULE_EVENTS).where(occurred_at: ..at).reverse_chronological.pluck(:metadata)
      rows.each_with_object({}) do |metadata, states|
        metadata = parse(metadata)
        key = metadata["key"]
        after = metadata["after"]
        next unless key && after.is_a?(Hash)

        current = states[key.to_sym]
        states[key.to_sym] = after if current.nil? || after["lock_version"].to_i > current["lock_version"].to_i
      end
    end

    # The newest `limit` rows about one flag, as the admin page shows them:
    # event, time, actor label, reason and revision. Never a unit key (the
    # rows hold none). Matches on the metadata's key, a Postgres JSON read.
    def entries(key, limit: 20)
      @log.where(event_type: Events.auditable).where("metadata->>'key' = ?", key.to_s)
          .reverse_chronological.limit(limit).pluck(:event_type, :occurred_at, :metadata).map do |event, occurred_at, metadata|
        metadata = parse(metadata)
        { event: event, occurred_at: occurred_at&.utc&.iso8601, actor: metadata["actor_label"],
          reason: metadata["reason"], revision: metadata["revision"] }
      end
    end

    private

    def parse(metadata)
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      metadata.is_a?(Hash) ? metadata.transform_keys(&:to_s) : {}
    end
  end
end
