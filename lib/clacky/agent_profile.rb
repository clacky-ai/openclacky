# frozen_string_literal: true

require "yaml"

module Clacky
  # Loads and represents an agent profile (system prompt + skill whitelist).
  #
  # Lookup order for a profile named "coding":
  #   1. ~/.clacky/agents/coding/                (user override, physical dir)
  #   2. extension agent unit with id == "coding" (ext.yml contributes.agents)
  #
  # Each user profile directory (opt-in override) contains:
  #   - profile.yml       — name, description, skills whitelist
  #   - system_prompt.md  — agent-specific system prompt content
  #
  # Global files (shared across all agents) are user-only overrides:
  #   - ~/.clacky/agents/SOUL.md   — agent personality/values (else DEFAULT_SOUL)
  #   - ~/.clacky/agents/USER.md   — user profile info        (else DEFAULT_USER)
  # The universal behavioural rules (todo manager, tool usage, response style,
  # etc.) live in a bundled resource file at lib/clacky/prompts/base.md.
  class AgentProfile
    USER_AGENTS_DIR = File.expand_path("~/.clacky/agents").freeze
    BASE_PROMPT_PATH = File.expand_path("../prompts/base.md", __FILE__).freeze

    DEFAULT_SOUL = <<~MD.freeze
      You are calm, precise, and helpful. You communicate clearly and concisely.
      You are honest about uncertainty and ask for clarification when needed.
      You take initiative but respect the user's preferences and decisions.
    MD

    DEFAULT_USER = "(No user profile configured yet. To personalize, create ~/.clacky/agents/USER.md)"

    attr_reader :name, :description

    def initialize(name)
      @name = name.to_s
      result = ExtensionLoader.last_result
      @ext_unit = result&.agents&.find { |u| u.id == @name }
      if @ext_unit.nil?
        result = ExtensionLoader.load_all(force: true)
        @ext_unit = result&.agents&.find { |u| u.id == @name }
      end
      @profile_data = load_profile_yml
      @description = @profile_data["description"] || ""
      @system_prompt_content = load_agent_file("system_prompt.md")
    end

    # Skills explicitly disabled for this agent, matched by skill identifier.
    # Declared via `disabled_skills` in profile.yml or the ext agent spec.
    # @return [Array<String>]
    def disabled_skills
      @disabled_skills ||= Array(@profile_data["disabled_skills"]).map(&:to_s)
    end

    # Whether a skill is usable by this agent: it must not be in the agent's
    # disabled list AND must be allowed by the skill's own `agent:` declaration.
    # @param skill [Skill]
    # @return [Boolean]
    def skill_allowed?(skill)
      return false if disabled_skills.include?(skill.identifier)
      skill.allowed_for_agent?(name)
    end

    # @param name [String, Symbol] profile name (e.g. "coding", "general")
    # @return [AgentProfile]
    def self.load(name)
      new(name)
    end

    # List all available agent profiles across user + extension layers.
    # Precedence on id collision: user override → extension unit.
    # @param recency [Hash<String, Integer>] agent id => epoch of last use,
    #   used to order third-party extension agents by most-recently-used
    #   instead of their static `order` field.
    # @return [Array<Hash>] each: { id:, title:, title_zh:, description:, description_zh:, source:, order:, layer:, author:, avatar: }
    def self.all(recency: {})
      out = {}

      add = lambda do |id, title, title_zh, description, description_zh, source, order, layer, author, avatar|
        next if id.nil? || id.empty?
        out[id] = {
          id: id,
          title: title,
          title_zh: title_zh,
          description: description,
          description_zh: description_zh,
          source: source,
          order: order,
          layer: layer,
          author: author,
          avatar: avatar,
        }
      end

      ext_result = ExtensionLoader.last_result || ExtensionLoader.load_all
      ext_result&.agents&.each do |unit|
        spec = unit.spec || {}
        next if spec["hidden"]
        title = spec["title"].to_s
        title = unit.id if title.empty?
        avatar = spec["avatar_abs"].to_s.empty? ? nil : "/agent_avatar/#{unit.id}"
        add.call(
          unit.id, title, spec["title_zh"].to_s,
          spec["description"].to_s, spec["description_zh"].to_s,
          "extension", spec["order"], unit.layer.to_s,
          spec["author"].to_s, avatar
        )
      end

      Dir.glob(File.join(USER_AGENTS_DIR, "*")).sort.each do |path|
        next unless File.directory?(path)
        id = File.basename(path)
        next if id.start_with?("_")
        next unless File.file?(File.join(path, "profile.yml"))
        meta = read_profile_yml(File.join(path, "profile.yml"))
        user_avatar = File.file?(File.join(path, "avatar.png")) ? "/agent_avatar/#{id}" : nil
        add.call(
          id, meta["title"] || meta["name"] || id, meta["title_zh"].to_s,
          meta["description"].to_s, meta["description_zh"].to_s,
          "user", meta["order"], "user",
          meta["author"].to_s.empty? ? "You" : meta["author"].to_s, user_avatar
        )
      end

      # Builtin agents always come first, then user overrides, then third-party
      # extension agents — so the "start new session" grid keeps the official
      # agents grouped ahead of anything the user installed from the market.
      # Within the third-party group, agents are ordered by most-recently-used
      # first (via `recency`), falling back to their static `order` field for
      # agents that have never been used yet.
      layer_rank = lambda do |a|
        next 0 if a[:layer] == "builtin"
        next 1 if a[:source] == "user"

        2
      end
      out.values.sort_by do |a|
        rank = layer_rank.call(a)
        if rank == 2
          [rank, -(recency[a[:id]] || 0), a[:order] || 999, a[:id]]
        else
          [rank, a[:order] || 999, a[:id]]
        end
      end
    end

    private_class_method def self.read_profile_yml(path)
      return {} unless File.file?(path)
      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    # @return [String] agent-specific system prompt content
    def system_prompt
      @system_prompt_content
    end

    # @return [String] base prompt shared by all agents (bundled resource)
    def base_prompt
      return "" unless File.file?(BASE_PROMPT_PATH)
      File.read(BASE_PROMPT_PATH).strip
    end

    # @return [String] soul content (user override, else default)
    def soul
      user_path = File.join(USER_AGENTS_DIR, "SOUL.md")
      if File.exist?(user_path) && !File.zero?(user_path)
        File.read(user_path).strip
      else
        DEFAULT_SOUL.strip
      end
    end

    # @return [String] user profile content (user override, else default)
    def user_profile
      user_path = File.join(USER_AGENTS_DIR, "USER.md")
      if File.exist?(user_path) && !File.zero?(user_path)
        File.read(user_path).strip
      else
        DEFAULT_USER
      end
    end

    private def load_profile_yml
      user_yml = File.join(user_agent_dir, "profile.yml")
      if File.file?(user_yml)
        return YAML.safe_load(File.read(user_yml)) || {}
      end

      if @ext_unit
        return {
          "name"        => @name,
          "description" => @ext_unit.spec["description"],
          "panels"      => @ext_unit.spec["panels"],
          "skills"      => @ext_unit.spec["skills"],
          "disabled_skills" => @ext_unit.spec["disabled_skills"],
        }
      end

      raise ArgumentError, "Agent profile '#{@name}' not found. " \
        "Looked in #{user_agent_dir} and extension registry."
    end

    # Agent-specific file lookup: user override → extension prompt (system_prompt.md only).
    private def load_agent_file(filename)
      user_path = File.join(user_agent_dir, filename)
      return File.read(user_path).strip if File.exist?(user_path) && !File.zero?(user_path)

      if @ext_unit && filename == "system_prompt.md"
        prompt_abs = @ext_unit.spec["prompt_abs"]
        return File.read(prompt_abs).strip if prompt_abs && File.file?(prompt_abs)
      end

      ""
    end

    private def user_agent_dir
      File.join(USER_AGENTS_DIR, @name)
    end
  end
end
