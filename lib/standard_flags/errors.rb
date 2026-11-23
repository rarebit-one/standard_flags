module StandardFlags
  class Error < StandardError; end

  # Raised while building the registry: a bad declaration fails boot rather
  # than misbehaving at read time.
  class DefinitionError < Error; end

  # Raised for an undeclared key when `config.strict` is on (the default
  # outside production). In production the read returns a fail-safe result
  # with reason ERROR and error code FLAG_NOT_FOUND instead.
  class UnknownFlag < Error; end

  # Raised in strict mode when a reader doesn't match the flag's kind, for
  # example `on?` on a mode.
  class TypeMismatch < Error; end

  # Raised by `StandardFlags::Job.requires_flag ..., retry: true` when the
  # flag is off, so `retry_on StandardFlags::Disabled` can reschedule the job.
  class Disabled < Error
    attr_reader :key

    def initialize(key, message = nil)
      @key = key.to_sym
      super(message || "flag :#{@key} is disabled")
    end
  end

  # Reported (never raised) through Rails.error when an ENV pin can't be
  # parsed. The message names the variable, never its value.
  class PinRejected < Error; end

  # Reported (never raised) through Rails.error when a `forbidden_in` flag is
  # pinned on in an environment that forbids it.
  class ForbiddenPin < Error; end

  # Reported (never raised) through Rails.error when a stored runtime rule
  # holds something its flag can't serve. Only that flag fails.
  class RuleInvalid < Error; end
end
