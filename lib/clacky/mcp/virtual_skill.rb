# frozen_string_literal: true

require_relative "../skill"

module Clacky
  module Mcp
    # In-memory Skill that surfaces a configured MCP server in the agent's
    # AVAILABLE MCP SERVERS section. When invoked, it forks a subagent whose
    # only job is to operate this server.
    #
    # The subagent does NOT receive a Ruby-side bridge tool. It calls the
    # server through the local Clacky HTTP API using whichever shell-style
    # tool is already available (curl + the `terminal` tool, etc.). This makes
    # MCP indistinguishable from any other skill at the system-prompt level —
    # there is no second layer for the LLM to misunderstand.
    class VirtualSkill < Clacky::Skill
      attr_reader :mcp_server_name

      def initialize(server_name:, description:)
        @mcp_server_name = server_name

        @directory       = Pathname.new("/dev/null/mcp/#{server_name}")
        @source_path     = @directory
        @brand_skill     = false
        @brand_config    = nil
        @cached_metadata = nil
        @encrypted       = false
        @warnings        = []
        @invalid         = false
        @invalid_reason  = nil
        @frontmatter     = {}

        @name        = "mcp:#{server_name}"
        @description = description
        @name_zh        = nil
        @description_zh = nil

        @user_invocable           = true
        @disable_model_invocation = false
        @allowed_tools  = nil
        @context        = nil
        @agent_type     = nil
        @argument_hint  = nil
        @hooks          = nil
        @fork_agent     = true
        @model          = nil
        @forbidden_tools = nil
        @auto_summarize = true

        @content = build_content
      end

      def encrypted?
        false
      end

      def has_supporting_files?
        false
      end

      def supporting_files
        []
      end

      def process_content(shell_output: {}, template_context: {}, script_dir: nil)
        @content
      end

      def to_h
        super.merge(mcp: true, mcp_server: @mcp_server_name)
      end

      private def build_content
        <<~MD
          # MCP Server: #{@mcp_server_name}

          You are a subagent operating the **#{@mcp_server_name}** MCP server through
          the local Clacky HTTP API. Talk to it the same way you would talk to any
          other HTTP service — there is no special MCP tool in your registry.

          ## Endpoint

          The Clacky server exposes this MCP server at:

              http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/mcp/#{@mcp_server_name}

          Both env vars are already exported in your shell environment.

          ## Step 1 — Discover available tools

          Run this once at the start of the task to see the live tool catalog:

              curl -s "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/mcp/#{@mcp_server_name}/tools"

          The response shape:

              { "ok": true, "name": "#{@mcp_server_name}", "tools": [
                  { "name": "...", "description": "...", "input_schema": { ... } },
                  ...
              ] }

          Read each tool's `input_schema` to understand its required arguments.

          ## Step 2 — Invoke a tool

              curl -s -X POST "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/mcp/#{@mcp_server_name}/call" \\
                -H "Content-Type: application/json" \\
                -d '{"tool":"<tool_name>","arguments":{ ... }}'

          The response shape:

              { "ok": true,  "result": <raw MCP tools/call result> }
              { "ok": false, "error":  "<message>" }

          The raw `result` typically contains a `content` array with `text` /
          `image` / `resource` parts — extract what you need.

          ## Workflow

          1. Understand the task delegated by the parent agent.
          2. List tools (Step 1) if you don't already know what's available.
          3. Pick the right tool(s); call them (Step 2) with valid arguments
             matching each tool's `input_schema`.
          4. Return a concise summary of what was accomplished and any results
             the parent agent needs. Do not chit-chat — the parent only sees
             your final response.
        MD
      end
    end
  end
end
