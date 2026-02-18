# frozen_string_literal: true

require "yaml"
require "pathname"

module Clacky
  # Represents a skill with its metadata and content.
  # A skill is defined by a SKILL.md file with optional YAML frontmatter.
  class Skill
    # Frontmatter fields that are recognized
    FRONTMATTER_FIELDS = %w[
      name
      description
      disable-model-invocation
      user-invocable
      allowed-tools
      context
      agent
      argument-hint
      hooks
      fork_agent
      model
      forbidden_tools
      auto_summarize
    ].freeze

    attr_reader :directory, :frontmatter, :source_path
    attr_reader :name, :description, :content
    attr_reader :disable_model_invocation, :user_invocable
    attr_reader :allowed_tools, :context, :agent_type, :argument_hint, :hooks
    attr_reader :fork_agent, :model, :forbidden_tools, :auto_summarize

    # @param directory [Pathname, String] Path to the skill directory
    # @param source_path [Pathname, String, nil] Optional source path for priority resolution
    def initialize(directory, source_path: nil)
      @directory = Pathname.new(directory)
      @source_path = source_path ? Pathname.new(source_path) : @directory

      load_skill
    end

    # Get the skill identifier (uses name from frontmatter or directory name)
    # @return [String]
    def identifier
      @name || @directory.basename.to_s
    end

    # Check if skill can be invoked by user via slash command
    # @return [Boolean]
    def user_invocable?
      @user_invocable.nil? || @user_invocable
    end

    # Check if skill can be automatically invoked by the model
    # @return [Boolean]
    def model_invocation_allowed?
      !@disable_model_invocation
    end

    # Check if this skill should fork a subagent
    # @return [Boolean]
    def fork_agent?
      @fork_agent == true
    end

    # Get the model to use for the subagent (if fork_agent is true)
    # @return [String, nil]
    def subagent_model
      @model
    end

    # Get the list of forbidden tools for the subagent
    # @return [Array<String>]
    def forbidden_tools_list
      @forbidden_tools || []
    end

    # Check if subagent should auto-summarize results
    # @return [Boolean]
    def auto_summarize?
      @auto_summarize != false
    end

    # Get the slash command for this skill
    # @return [String] e.g., "/explain-code"
    def slash_command
      "/#{identifier}"
    end

    # Get the description for context loading
    # Returns the description from frontmatter, or first paragraph of content
    # @return [String]
    def context_description
      @description || extract_first_paragraph
    end

    # Get all supporting files in the skill directory (excluding SKILL.md)
    # @return [Array<Pathname>]
    def supporting_files
      return [] unless @directory.exist?

      @directory.children.reject { |p| p.basename.to_s == "SKILL.md" }
    end

    # Check if this skill has supporting files
    # @return [Boolean]
    def has_supporting_files?
      supporting_files.any?
    end

    # Process the skill content with argument substitution
    # @param arguments [String] Arguments passed to the skill
    # @param shell_output [Hash] Shell command outputs for !command` syntax (optional)
    # @return [String] Processed content
    def process_content(arguments = "", shell_output: {})
      processed_content = @content.dup

      # Replace argument placeholders
      processed_content = substitute_arguments(processed_content, arguments)

      # Replace shell command outputs
      shell_output.each do |command, output|
        placeholder = "!`#{command}`"
        processed_content.gsub!(placeholder, output.to_s)
      end

      # Append supporting files list if any exist
      if has_supporting_files?
        processed_content += "\n\n## Supporting Files\n\n"
        processed_content += "The following files are available in this skill's directory:\n\n"
        supporting_files.each do |file|
          relative_path = file.relative_path_from(@directory)
          processed_content += "- `#{relative_path}`\n"
        end
      end

      processed_content
    end

    # Convert to a hash representation
    # @return [Hash]
    def to_h
      {
        name: identifier,
        description: context_description,
        directory: @directory.to_s,
        source_path: @source_path.to_s,
        user_invocable: user_invocable?,
        model_invocation_allowed: model_invocation_allowed?,
        fork_agent: fork_agent?,
        subagent_model: @model,
        forbidden_tools: @forbidden_tools,
        allowed_tools: @allowed_tools,
        argument_hint: @argument_hint,
        content_length: @content.length
      }
    end

    # Load content of a supporting file
    # @param filename [String] Relative path from skill directory
    # @return [String, nil] File contents or nil if not found
    def read_supporting_file(filename)
      file_path = @directory.join(filename)
      file_path.exist? ? file_path.read : nil
    end

    private

    def load_skill
      skill_file = @directory.join("SKILL.md")

      unless skill_file.exist?
        raise Clacky::AgentError, "SKILL.md not found in skill directory: #{@directory}"
      end

      content = skill_file.read

      # Parse frontmatter if present
      if content.start_with?("---")
        parse_frontmatter(content)
      else
        @frontmatter = {}
        @content = content
      end

      # Set defaults
      @user_invocable = true if @user_invocable.nil?
      @disable_model_invocation = false if @disable_model_invocation.nil?

      validate_frontmatter
    end

    def parse_frontmatter(content)
      # Extract frontmatter between first and second "---"
      frontmatter_match = content.match(/^---\n(.*?)\n---/m)

      unless frontmatter_match
        raise Clacky::AgentError, "Invalid frontmatter format in SKILL.md: missing closing ---"
      end

      yaml_content = frontmatter_match[1]
      @frontmatter = YAML.safe_load(yaml_content) || {}

      # Extract content after frontmatter
      @content = content[frontmatter_match.end(0)..-1].to_s.strip

      # Extract fields from frontmatter
      @name = @frontmatter["name"]
      @description = @frontmatter["description"]
      @disable_model_invocation = @frontmatter["disable-model-invocation"]
      @user_invocable = @frontmatter["user-invocable"]
      @allowed_tools = @frontmatter["allowed-tools"]
      @context = @frontmatter["context"]
      @agent_type = @frontmatter["agent"]
      @argument_hint = @frontmatter["argument-hint"]
      @hooks = @frontmatter["hooks"]
      
      # Subagent configuration
      @fork_agent = @frontmatter["fork_agent"]
      @model = @frontmatter["model"]
      @forbidden_tools = @frontmatter["forbidden_tools"]
      @auto_summarize = @frontmatter["auto_summarize"]
    end

    def validate_frontmatter
      # Validate name if provided
      if @name
        unless @name.match?(/^[a-z0-9][a-z0-9-]*$/)
          raise Clacky::AgentError,
            "Invalid skill name '#{@name}'. Use lowercase letters, numbers, and hyphens only (max 64 chars)."
        end
        if @name.length > 64
          raise Clacky::AgentError, "Skill name '#{@name}' exceeds 64 characters."
        end
      end

      # Validate forbidden_tools format
      if @forbidden_tools && !@forbidden_tools.is_a?(Array)
        raise Clacky::AgentError, "forbidden_tools must be an array of tool names"
      end

      # Validate allowed-tools format
      if @allowed_tools && !@allowed_tools.is_a?(Array)
        raise Clacky::AgentError, "allowed-tools must be an array of tool names"
      end
    end

    def extract_first_paragraph
      @content.split(/\n\n/).first.to_s
    end

    def substitute_arguments(content, arguments)
      # Parse arguments as shell words for indexed access
      args_array = arguments.shellsplit

      # Replace $ARGUMENTS with all arguments
      result = content.gsub("$ARGUMENTS", arguments.to_s)

      # Replace $ARGUMENTS[N] with specific argument
      result.gsub!(/\$ARGUMENTS\[(\d+)\]/) do
        index = $1.to_i
        args_array[index] || ""
      end

      # Replace $N shorthand ($0, $1, etc.)
      result.gsub!(/\$([0-9]+)/) do
        index = $1.to_i
        args_array[index] || ""
      end

      # Replace ${CLAUDE_SESSION_ID} with empty string (session not available in current context)
      result.gsub!(/\${CLAUDE_SESSION_ID}/, "")

      result
    end
  end
end
