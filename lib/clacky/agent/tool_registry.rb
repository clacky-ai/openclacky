# frozen_string_literal: true

module Clacky
  class ToolRegistry
    def initialize
      @tools = {}
    end

    def register(tool)
      @tools[tool.name] = tool
    end

    def get(name)
      # Handle shell alias to safe_shell for backward compatibility
      name = 'safe_shell' if name == 'shell' && @tools.key?('safe_shell') && !@tools.key?('shell')
      
      @tools[name] || raise(Clacky::ToolCallError, "Tool not found: #{name}")
    end

    def all
      @tools.values
    end

    def all_definitions
      @tools.values.map(&:to_function_definition)
    end

    def allowed_definitions(allowed_tools = nil)
      return all_definitions if allowed_tools.nil? || allowed_tools.include?("all")

      @tools.select { |name, _| allowed_tools.include?(name) }
             .values
             .map(&:to_function_definition)
    end

    def tool_names
      @tools.keys
    end

    def by_category(category)
      @tools.values.select { |tool| tool.category == category }
    end
  end
end
