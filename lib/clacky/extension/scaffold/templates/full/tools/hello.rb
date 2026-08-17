# frozen_string_literal: true

module Clacky
  module Tools
    # Example extension-contributed tool. The file name maps to this class
    # name (tools/hello.rb → Clacky::Tools::Hello); it is injected only into
    # agents that declare `tools: [hello]`.
    class Hello < Base
      self.tool_name = "hello"
      self.tool_description = "Say hello to the user, echoing an optional name."
      self.tool_category = "general"
      self.tool_parameters = {
        type: "object",
        properties: {
          name: {
            type: "string",
            description: "Who to greet"
          }
        },
        required: []
      }

      def execute(name: nil, **)
        { message: "Hello, #{name || 'world'}!" }
      end
    end
  end
end
