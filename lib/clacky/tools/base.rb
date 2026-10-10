# frozen_string_literal: true

require_relative "../utils/environment_detector"

module Clacky
  module Tools
    class Base
      class << self
        attr_accessor :tool_name, :tool_description, :tool_parameters, :tool_category

        # Opt in to receive the current call's id as :tool_call_id. Needed by
        # tools that fan out to subagents so their transcripts can be anchored
        # to the tool result they belong to.
        attr_accessor :receives_tool_call_id
      end

      # Host agent, injected at registration for extension tools so they can
      # reach its public API (fan_out_labeled, fork_subagent, skill_loader).
      attr_accessor :agent

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

      # Expand ~ to home directory only if path starts with ~
      # Relative paths are resolved against working_dir if provided.
      # On WSL, Windows-style paths (C:\..., C:/..., /C:/...) are translated to
      # their /mnt/<drive>/... equivalents so that paths copied from Windows
      # (clipboard, error messages, file dialogs) work unchanged.
      # @param path [String, nil] The path to expand
      # @param working_dir [String, nil] The working directory to resolve relative paths against
      # @return [String, nil] The expanded path, or original if no ~ present
      private def expand_path(path, working_dir: nil)
        return path if path.nil? || path.strip.empty?

        # WSL: normalize Windows drive paths BEFORE anything else, otherwise
        # the leading "C:" makes File.expand_path treat them as relative.
        path = Clacky::Utils::EnvironmentDetector.win_to_linux_path(path)

        return File.expand_path(path) if path.start_with?("~")
        return File.expand_path(path, working_dir) if working_dir && !path.start_with?("/")
        # Always resolve relative paths to absolute (even without working_dir), so callers
        # never receive a bare "." that resolves against the process cwd unexpectedly.
        return File.expand_path(path) unless path.start_with?("/")

        path
      end

      # Format tool call for display - can be overridden by subclasses
      # @param args [Hash] The arguments passed to the tool
      # @return [String] Formatted call description (e.g., "Read(file.rb)")
      def format_call(args)
        "#{name}(...)"
      end

      # Format tool result for display - can be overridden by subclasses
      # @param result [Object] The result returned by execute
      # @return [String] Formatted result summary (e.g., "Read 150 lines")
      def format_result(result)
        if result.is_a?(Hash) && result[:message]
          result[:message]
        elsif result.is_a?(String)
          result.length > 100 ? "#{result[0..100]}..." : result
        else
          "Done"
        end
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
