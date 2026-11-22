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
        # Unit keys can be phone numbers or emails; keep them out of inspect
        # output, on top of what the host filters (Rails has copied the
        # host's filter_parameters onto ActiveRecord::Base by now).
        self.filter_attributes += [ :unit_key ]
      end

      class State < Record
        self.table_name = "standard_flags_state"
      end
    end
  end
end
