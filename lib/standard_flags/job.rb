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
  module Job
    extend ActiveSupport::Concern

    class_methods do
      def requires_flag(key, **options)
        retryable = options.fetch(:retry, false)
        context = options[:for]
        unknown = options.keys - %i[retry for]
        raise ArgumentError, "unknown option(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

        before_perform do
          target = context.respond_to?(:call) ? instance_exec(&context) : context
          next if StandardFlags.reader(for: target).enabled?(key)
          raise StandardFlags::Disabled, key if retryable

          logger&.info("[standard_flags] discarded #{self.class.name} (#{job_id}): flag :#{key} is disabled")
          throw :abort
        end
      end
    end
  end
end
