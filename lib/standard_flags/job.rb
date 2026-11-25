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
  # `client:` evaluates the flag for a client too (a StandardFlags::Client
  # or a `{ platform:, version:, build: }` Hash, or a lambda evaluated in the
  # job instance that returns one), for a job working on behalf of a mobile
  # or device request. Jobs never read request headers; pass the client the
  # request saw (`client.to_h` serialises).
  #
  #   requires_flag :new_importer, for: -> { arguments.first }, client: -> { arguments.second }
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

    OPTIONS = %i[retry for error client].freeze

    class_methods do
      def requires_flag(key, **options)
        retryable = options.fetch(:retry, false)
        context = options[:for]
        client = options[:client]
        error = options[:error]
        unknown = options.keys - OPTIONS
        raise ArgumentError, "unknown option(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

        StandardFlags::Job.check_error!(error, options) if options.key?(:error)

        before_perform do
          target = context.respond_to?(:call) ? instance_exec(&context) : context
          calling = client.respond_to?(:call) ? instance_exec(&client) : client
          target = Context.wrap(target, client: calling) unless calling.nil?
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
