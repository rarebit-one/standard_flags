module StandardFlags
  module Operations
    # Raised inside an operation to stop it (rolling back its write) with a
    # failed Result. Never escapes an operation.
    #
    # @api private
    class Failure < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end
  end
end
