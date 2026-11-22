module StandardFlags
  # Why an evaluation returned its value. The OpenFeature reasons, plus two of
  # our own: ENV_PIN (an environment variable decided) and KILL_SWITCH (a kill
  # switch was pinned off). OpenFeature treats reasons as an open set.
  module Reason
    STATIC = "STATIC".freeze
    DEFAULT = "DEFAULT".freeze
    TARGETING_MATCH = "TARGETING_MATCH".freeze
    SPLIT = "SPLIT".freeze
    DISABLED = "DISABLED".freeze
    ERROR = "ERROR".freeze
    ENV_PIN = "ENV_PIN".freeze
    KILL_SWITCH = "KILL_SWITCH".freeze

    ALL = [ STATIC, DEFAULT, TARGETING_MATCH, SPLIT, DISABLED, ERROR, ENV_PIN, KILL_SWITCH ].freeze
  end

  # The closed OpenFeature error-code set. Set only when the reason is ERROR.
  module ErrorCode
    FLAG_NOT_FOUND = "FLAG_NOT_FOUND".freeze
    PARSE_ERROR = "PARSE_ERROR".freeze
    TYPE_MISMATCH = "TYPE_MISMATCH".freeze
    TARGETING_KEY_MISSING = "TARGETING_KEY_MISSING".freeze
    INVALID_CONTEXT = "INVALID_CONTEXT".freeze
    PROVIDER_NOT_READY = "PROVIDER_NOT_READY".freeze
    PROVIDER_FATAL = "PROVIDER_FATAL".freeze
    GENERAL = "GENERAL".freeze

    ALL = [
      FLAG_NOT_FOUND, PARSE_ERROR, TYPE_MISMATCH, TARGETING_KEY_MISSING,
      INVALID_CONTEXT, PROVIDER_NOT_READY, PROVIDER_FATAL, GENERAL
    ].freeze
  end
end
