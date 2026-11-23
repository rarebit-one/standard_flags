module StandardFlags
  # Who an operation runs as when no person does: a rake task, a scheduled
  # plan, a guard. Pass it as `actor:`:
  #
  #   StandardFlags::Operations::Pause.call(:new_checkout, actor: StandardFlags::Actor.system("rake"), reason: "incident")
  #
  # The default `config.authorize` allows system actors and nothing else.
  class Actor
    attr_reader :name

    def self.system(name = "system")
      new(name)
    end

    def initialize(name)
      @name = name.to_s
      raise ArgumentError, "a system actor needs a name" if @name.strip.empty?

      freeze
    end

    def system?
      true
    end

    def to_s
      "system:#{name}"
    end
    alias_method :inspect, :to_s

    def ==(other)
      other.is_a?(Actor) && other.name == name
    end
    alias_method :eql?, :==

    def hash
      [ self.class, name ].hash
    end

    # How audit rows and notifications name an actor: `system:<name>`, or the
    # record's class and id. Never anything else about the actor.
    def self.label(actor)
      case actor
      when Actor then actor.to_s
      when nil then nil
      else actor.respond_to?(:id) && !actor.id.nil? ? "#{actor.class.name}:#{actor.id}" : actor.class.name
      end
    end
  end
end
