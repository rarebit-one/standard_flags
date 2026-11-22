require "digest"

module StandardFlags
  # Deterministic bucketing into 10,000 basis points. These functions are a
  # permanent contract: changing them would move every unit to a new bucket.
  # A new algorithm gets a new version; old flags keep theirs. The shared
  # conformance fixtures pin test vectors for every version.
  #
  # Not yet used by evaluation; runtime percentage rules build on it.
  module Bucket
    BUCKETS = 10_000
    DECISIONS = %w[rollout variant].freeze
    COLUMN_FORMAT = /\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?\z/

    module_function

    # Version 1: SHA-256 of "salt:unit_key", first 15 hex digits, mod 10,000.
    def v1(salt, unit_key)
      return nil if blank?(unit_key)

      bucket("#{salt}:#{unit_key}")
    end

    # Version 2, the default for new flags. The rollout check and the variant
    # choice hash different inputs, and the delimiters are explicit so two
    # different (salt, unit) pairs can never produce the same input.
    def v2(decision, salt, unit_key)
      decision = check_decision!(decision)
      return nil if blank?(unit_key)

      bucket("v2|#{decision}|#{salt}|#{unit_key}")
    end

    # The Postgres twin of `v2`, so counting eligible rows and serving agree.
    # Bind the salt with `sanitize_sql([sql, salt: salt])`. A NULL or blank
    # column yields NULL, matching `v2`'s nil, never a random bucket.
    def sql_v2(column:, decision: "rollout")
      decision = check_decision!(decision)
      raise ArgumentError, "column #{column.inspect} is not a plain identifier" unless column.to_s.match?(COLUMN_FORMAT)

      unit = "(CASE WHEN btrim(#{column}::text) = '' THEN NULL ELSE #{column}::text END)"
      "('x' || substr(encode(sha256(convert_to('v2|#{decision}|' || :salt || '|' || #{unit}, 'UTF8')), " \
        "'hex'), 1, 15))::bit(60)::bigint % #{BUCKETS}"
    end

    def bucket(input)
      Digest::SHA256.hexdigest(input)[0, 15].to_i(16) % BUCKETS
    end

    def check_decision!(decision)
      decision = decision.to_s
      raise ArgumentError, "decision must be one of #{DECISIONS.inspect}" unless DECISIONS.include?(decision)

      decision
    end

    def blank?(unit_key)
      unit_key.nil? || unit_key.to_s.strip.empty?
    end
  end
end
