module StandardFlags
  module Operations
    # Records each change (R16). Inside the operation's transaction
    # (`record`), only the audit row, and only when standard_audit is loaded
    # and enabled:
    #
    # * through StandardAudit::Operation's `audit!`, or,
    # * when the app subscribes standard_audit to the event (for example with
    #   `StandardFlags::Events.auditable`), by publishing the event there, so
    #   its subscriber writes the row. One row either way.
    #
    # Either runs in its own savepoint. standard_audit swallows a failed
    # write by default, and on Postgres a failed statement aborts the whole
    # transaction; the savepoint confines that to the audit row. A failure
    # the savepoint catches (or any error the writer raises) fails the
    # operation with :audit_failed, rolled back, when standard_audit's
    # `raise_on_audit_write_error` is set; otherwise it is reported and the
    # change commits without its row, as standard_audit's own default does.
    # (A failure standard_audit's subscriber swallows before reaching the
    # database leaves nothing to detect; it reports those itself.)
    #
    # Once the change has committed (`announce`), never while its locks are
    # held:
    #
    # * the event itself (`standard_flags.flag.ramped` and so on), through
    #   ActiveSupport::Notifications, unless `record` already published it;
    # * `change.standard_flags`, a one-line summary for the gem's own
    #   subscribers (the Logger line, `config.add_notifier`).
    #
    # The row's metadata is the event payload without `actor`: the actor's
    # label, the reason, the key or cohort, the new revision, and the full
    # rule or cohort state before and after. Membership changes add the
    # unit, the value and counts. No unit key ever appears.
    #
    # @api private
    module Audit
      WRITER_LOCK = Mutex.new

      module_function

      # Inside the write. Returns true when it published the event.
      def record(tx, event, payload)
        if direct?(event)
          isolated(tx, event) { write(event, payload) }
          false
        elsif subscribed?(event)
          isolated(tx, event) { ActiveSupport::Notifications.instrument(event, payload) }
          true
        else
          false
        end
      end

      # After the commit. Never raises.
      def announce(event, payload, published:)
        Reporting.publish(event, payload) unless published
        Reporting.instrument(:change, event: event, key: payload[:key], cohort: payload[:cohort],
                                      actor: payload[:actor_label], revision: payload[:revision],
                                      store_revision: payload[:store_revision])
      end

      # Whether this process writes the row itself.
      def direct?(event)
        enabled? && !subscribed?(event)
      end

      # Whether standard_audit's subscriber writes the row for this event.
      def subscribed?(event)
        enabled? && Array(::StandardAudit.config.respond_to?(:subscriptions) ? ::StandardAudit.config.subscriptions : nil).any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(event) : pattern.to_s == event
        end
      end

      def enabled?
        return false unless defined?(::StandardAudit::Operation) && ::StandardAudit.respond_to?(:config)

        config = ::StandardAudit.config
        !(config.respond_to?(:enabled) && !config.enabled)
      end

      def raise_on_write_error?
        return false unless enabled?

        config = ::StandardAudit.config
        config.respond_to?(:raise_on_audit_write_error) && config.raise_on_audit_write_error ? true : false
      end

      def isolated(tx, event, &)
        tx.isolated(&)
      rescue Failure
        raise
      rescue StandardError => e
        raise if e.class.name == "StandardAudit::Operation::DeclarationError"
        if raise_on_write_error?
          raise Failure.new(:audit_failed, "the audit row could not be written (#{e.class}); nothing was changed")
        end

        Reporting.report(Error.new("the audit row for #{event} was not written (#{e.class}); the change was kept"), event: event)
      end

      def write(event, payload)
        writer.new.write(event, actor: payload[:actor], metadata: payload.except(:actor))
      rescue StandardError => e
        # standard_audit's own declaration check (dev and test only) always
        # propagates, as it does for any operation.
        raise if e.class.name == "StandardAudit::Operation::DeclarationError"

        # Only reached when the app sets raise_on_audit_write_error; by
        # default standard_audit reports a failed write and carries on.
        raise Failure.new(:audit_failed, "the audit row could not be written (#{e.class}); nothing was changed")
      end

      # Forgets the writer class, so the next write builds it again. For the
      # gem's own specs.
      def reset!
        WRITER_LOCK.synchronize do
          Operations.send(:remove_const, :AuditWriter) if Operations.const_defined?(:AuditWriter, false)
        end
      end

      # StandardFlags::Operations::AuditWriter, the one class that writes
      # standard_flags audit rows through standard_audit. Built the first
      # time it's needed, so neither gem has to load before the other. It is
      # named before it includes the contract, so standard_audit registers a
      # named operation.
      def writer
        WRITER_LOCK.synchronize do
          next Operations::AuditWriter if Operations.const_defined?(:AuditWriter, false)

          klass = Operations.const_set(:AuditWriter, Class.new do
            def write(action, **attributes)
              audit!(action, **attributes)
            end
          end)
          klass.include(::StandardAudit::Operation)
          klass.audits(*Events::AUDITABLE)
          klass
        end
      end
    end
  end
end
