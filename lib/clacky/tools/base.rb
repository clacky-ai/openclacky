# frozen_string_literal: true

module Clacky
  module Tools
    class Base
      class << self
        attr_accessor :tool_name, :tool_description, :tool_parameters, :tool_category
      end

      def name
        self.class.tool_name
      end

      def description
        self.class.tool_description
      end

      def parameters
        self.class.tool_parameters
      end

      def category
        self.class.tool_category || "general"
      end

      # Execute the tool - must be implemented by subclasses
      def execute(**_args)
        raise NotImplementedError, "#{self.class.name} must implement #execute"
      end

      # Convert to OpenAI function calling format
      def to_function_definition
        {
          type: "function",
          function: {
            name: name,
            description: description,
            parameters: parameters
          }
        }
      end
    end
  end
end
