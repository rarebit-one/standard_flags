module StandardFlags
  # Staged rollout for a mode declared with `preset: :sensor`:
  #
  #   StandardFlags.sensor(:strict_gates, for: run) do |s|
  #     s.observe { Gates.evaluate(run) }          # runs in sensor and on
  #     s.enforce { |verdict| hold!(run, verdict) } # runs only in on
  #   end
  #
  # * off    — neither block runs; returns nil.
  # * sensor — observe runs and its result goes into a `sensor.standard_flags`
  #            notification; returns the observation. An exception in observe
  #            is reported and swallowed, because sensor mode must not change
  #            behaviour.
  # * on     — observe runs, the notification fires, then enforce receives
  #            the observation; returns enforce's result. Exceptions propagate.
  class Sensor
    VALUES = Definition::PRESETS.fetch(:sensor)

    def self.run(reader, key)
      sensor = new
      yield sensor
      sensor.call(reader, key)
    end

    def observe(&block)
      @observe = block
    end

    def enforce(&block)
      @enforce = block
    end

    def call(reader, key)
      mode = reader.mode(key)
      return unless sensor_preset?(key, mode)

      case mode.value
      when :sensor then observe_safely(key)
      when :on then enforce_after(key)
      end
    end

    private

    # A non-sensor mode raises when strict and runs nothing otherwise.
    def sensor_preset?(key, mode)
      return false if mode.unknown?
      return true if mode.values == VALUES

      message = "flag :#{key} is not a sensor mode (declare it with preset: :sensor)"
      raise TypeMismatch, message if StandardFlags.config.strict?

      Reporting.once(:sensor_preset, key.to_sym) { Reporting.report(TypeMismatch.new(message)) }
      false
    end

    def observe_safely(key)
      observed = @observe&.call
      notify(key, :sensor, observed)
      observed
    rescue StandardError => e
      Reporting.report(e, flag: key.to_s, mode: "sensor")
      notify(key, :sensor, nil, e)
      nil
    end

    def enforce_after(key)
      observed = @observe&.call
      notify(key, :on, observed)
      @enforce ? @enforce.call(observed) : observed
    end

    def notify(key, mode, observed, error = nil)
      Reporting.instrument(:sensor, key: key.to_sym, mode: mode, observed: observed, error_class: error&.class&.name)
    end
  end
end
