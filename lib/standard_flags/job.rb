require "active_support/concern"

module StandardFlags
  # Job guards.
  #
  #   class ReplyJob < ApplicationJob
  #     include StandardFlags::Job
  #
  #     requires_flag :ai_assistant, retry: true, for: -> { arguments.first }
  #     retry_on StandardFlags::Disabled, wait: 5.minutes, attempts: 12
  #   end
  #
  # When the flag is off, `retry: true` raises StandardFlags::Disabled so
  # `retry_on` can reschedule; `retry: false` (the default) discards the job
  # without running it. `for:` is evaluated in the job instance.
  #
  # `error:` raises your own exception instead, for jobs that already
  # `retry_on` (or `discard_on`) it:
  #
  #   requires_flag :ai_assistant, error: UpstreamUnavailable
  #   requires_flag :ai_assistant, error: ->(key) { UpstreamUnavailable.new("#{key} off for #{arguments.first}") }
  #
  # A class is raised with the message "flag :<key> is disabled"; a proc
  # runs in the job instance, may take the key, and returns an exception (or
  # an exception class). `error:` always raises, so it never discards:
  # `retry: true` alongside it changes nothing, and `retry: false` is
  # rejected as a contradiction.
  module Job
    extend ActiveSupport::Concern

    OPTIONS = %i[retry for error].freeze

    class_methods do
      def requires_flag(key, **options)
        retryable = options.fetch(:retry, false)
        context = options[:for]
        error = options[:error]
        unknown = options.keys - OPTIONS
        raise ArgumentError, "unknown option(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

        StandardFlags::Job.check_error!(error, options) if options.key?(:error)

        before_perform do
          target = context.respond_to?(:call) ? instance_exec(&context) : context
          next if StandardFlags.reader(for: target).enabled?(key)

          standard_flags_raise!(key, error) if error
          raise StandardFlags::Disabled, key if retryable

          logger&.info("[standard_flags] discarded #{self.class.name} (#{job_id}): flag :#{key} is disabled")
          throw :abort
        end
      end
    end

    # @api private
    def self.check_error!(error, options)
      unless (error.is_a?(Class) && error <= Exception) || error.is_a?(Proc)
        raise ArgumentError, "error: must be an exception class or a proc returning an exception"
      end
      return unless options.key?(:retry) && !options[:retry]

      raise ArgumentError, "error: always raises; drop retry: false (which would discard the job)"
    end

    private

    def standard_flags_raise!(key, error)
      error = error.arity.zero? ? instance_exec(&error) : instance_exec(key.to_sym, &error) if error.is_a?(Proc)
      raise error, "flag :#{key} is disabled" if error.is_a?(Class)

      raise error
    end
  end
end
