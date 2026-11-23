require "active_record"

module StandardFlags
  module Runtime
    # ActiveRecord models over the runtime tables. Required only by
    # ActiveRecordStore, so a host with runtime rules off never loads
    # ActiveRecord through this gem. They live under lib/, not app/models,
    # so Rails never eager-loads them in a host without the tables.
    #
    # There are no associations: every read is one explicit query, which
    # keeps strict_loading and N+1 detectors quiet.
    #
    # Unit keys can be phone numbers or emails. A model's filter_attributes
    # only covers its own `inspect`; ActiveRecord filters SQL log binds
    # through ActiveRecord::Base's, so loading these models adds `unit_key`
    # there (Runtime.filter_unit_keys!). That is global, but the name is
    # narrow. It can't help when prepared statements are off, because the
    # values are then inlined into the SQL text; the health check warns.
    module Models
      class Record < ::ActiveRecord::Base
        self.abstract_class = true
      end

      class Rule < Record
        self.table_name = "standard_flags_rules"
      end

      class Cohort < Record
        self.table_name = "standard_flags_cohorts"
      end

      class Membership < Record
        self.table_name = "standard_flags_memberships"
      end

      class State < Record
        self.table_name = "standard_flags_state"
      end
    end

    Runtime.filter_unit_keys!(::ActiveRecord::Base)
  end
end
