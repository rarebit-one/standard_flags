module StandardFlags
  # What every operation returns, in the shape the host apps' own operations
  # use: `success?`, `value` and `errors` (human-readable messages), plus
  # `code`, a Symbol a caller can branch on, and `warnings`, messages about
  # a change that succeeded but may not do what the caller expects:
  #
  #   result = StandardFlags::Operations::Ramp.call(:new_checkout, bps: 500, actor: user, reason: "canary")
  #   result.success?  # => true
  #   result.value     # => { key: :new_checkout, rule: {...}, revision: 3, store_revision: 12 }
  #
  #   result.code      # on failure, e.g. :pinned_by_env, :stale_revision,
  #                    # :unauthorized, :invalid, :limit_exceeded
  #   result.warnings  # e.g. SetValue on a paused rule:
  #                    # ["rule is paused; the value is stored but not served until Start"]
  class Result
    attr_reader :value, :errors, :code, :warnings

    def self.success(value)
      new(success: true, value: value)
    end

    def self.failure(code, errors)
      new(success: false, code: code, errors: Array(errors))
    end

    def initialize(success:, value: nil, errors: [], code: nil, warnings: [])
      @success = success
      @value = value
      @errors = errors.map(&:to_s).freeze
      @code = code
      @warnings = warnings.map(&:to_s).freeze
      freeze
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    def inspect
      success? ? "#<StandardFlags::Result success>" : "#<StandardFlags::Result failure #{code} #{errors.inspect}>"
    end
  end
end
