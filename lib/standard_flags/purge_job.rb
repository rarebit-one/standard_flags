module StandardFlags
  # Deletes memberships removed or expired more than
  # `config.membership_retention` (default 90 days) ago, the same as
  # `bin/rails flags:purge`. Schedule it with the app's job scheduler, for
  # example daily. Autoloaded on first reference, which loads ActiveJob; an
  # app without activejob never defines it.
  class PurgeJob < ::ActiveJob::Base
    def perform
      return unless Runtime.enabled?

      Runtime.purge!
    end
  end
end
