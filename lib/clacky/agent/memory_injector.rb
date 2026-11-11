# frozen_string_literal: true

require "json"

module Clacky
  class Agent
    # Automatic long-term memory injection (opt-in: memory_inject_enabled).
    #
    # Before each user message a picker model (the provider's lite model, else
    # the primary) selects relevant files from a wide memories listing
    # (+load_memories_meta+); their bodies are appended as a system_injected
    # user message. Append-only keeps the prompt-cache prefix intact. Files
    # already injected on the active task chain are skipped; compression drops
    # those messages, which naturally allows re-injection later.
    #
    # Best-effort: any failure is logged and the turn proceeds without memories.
    module MemoryInjector
      MEMORY_INJECT_MAX_FILES = 3
      MEMORY_INJECT_FILE_BYTES = 4096
      MEMORY_INJECT_STALE_DAYS = 30
      MEMORY_PICKER_PREV_REPLY_CHARS = 600
      MEMORY_PICKER_USER_CHARS = 2000
      # Thinking models spend part of this budget on reasoning; 200 truncated the JSON.
      MEMORY_PICKER_MAX_TOKENS = 1024
      MEMORY_PICKER_READ_TIMEOUT = 20
      # The picker can't grep, so it needs a far wider view than the
      # 20-file LRU shortlist the recall/persist skills get.
      MEMORY_PICKER_LISTING_LIMIT = 200

      MEMORY_PICKER_SYSTEM_PROMPT = <<~PROMPT
        You select long-term memory files relevant to the user's latest message.
        A memory is relevant only if it would change how the assistant handles this message
        (preferences, conventions, project facts, prior decisions). Skip loosely related ones.
        Reply with JSON only: {"files": ["<filename>.md"]} using at most #{MEMORY_INJECT_MAX_FILES} filenames from the list.
        Reply {"files": []} when nothing is relevant (greetings, acknowledgements, small talk).
      PROMPT

      private def inject_relevant_memories(user_input, task_id:)
        return unless @config.memory_inject_enabled
        return if @is_subagent

        message = user_input.to_s.strip
        return if message.empty?
        return if Dir.glob(File.join(memories_base_dir, "*.md")).empty?

        visible = memory_visible_messages
        picked = pick_relevant_memories(message, visible) - injected_memory_files(visible)
        return if picked.empty?

        @history.append({
          role: "user",
          content: build_memory_reminder(picked),
          system_injected: true,
          memory_recall: true,
          memory_files: picked,
          task_id: task_id
        })
      rescue StandardError => e
        Clacky::Logger.warn("memory_inject.failed", error: e)
      end

      # Messages on the active task chain, so undone branches neither count as
      # injected nor feed the picker.
      private def memory_visible_messages
        chain = active_task_chain
        @history.to_a.select { |m| !m[:task_id] || chain.include?(m[:task_id]) }
      end

      private def injected_memory_files(messages)
        messages.select { |m| m[:memory_recall] }.flat_map { |m| Array(m[:memory_files]) }.uniq
      end

      private def pick_relevant_memories(message, visible)
        model = memory_picker_model
        # send_messages_with_tools rather than send_messages: only it returns usage.
        response = memory_picker_client(model).send_messages_with_tools(
          [
            { role: "system", content: MEMORY_PICKER_SYSTEM_PROMPT },
            { role: "user", content: memory_picker_prompt(message, visible) }
          ],
          model: model,
          tools: [],
          max_tokens: MEMORY_PICKER_MAX_TOKENS
        )
        track_auxiliary_cost(response[:usage], model: response[:routed_model] || model) if response[:usage]
        if response[:finish_reason] == "length"
          Clacky::Logger.warn("memory_inject.picker_truncated", model: model, max_tokens: MEMORY_PICKER_MAX_TOKENS)
        end
        parse_memory_picker_reply(response[:content].to_s)
          .select { |name| memory_file_name?(name) }
          .uniq
          .first(MEMORY_INJECT_MAX_FILES)
      end

      private def memory_picker_model
        lite = @config.lite_model_config_for_current
        (lite && lite["model"]) || current_model
      end

      # A dedicated client so a slow picker gives up quickly instead of holding
      # the turn for the main client's 300s read timeout.
      private def memory_picker_client(model)
        lite = @config.lite_model_config_for_current
        if lite
          Clacky::Client.new(
            lite["api_key"],
            base_url: lite["base_url"],
            model: model,
            anthropic_format: lite["anthropic_format"] == true,
            read_timeout: MEMORY_PICKER_READ_TIMEOUT
          )
        else
          Clacky::Client.new(
            @config.api_key,
            base_url: @config.base_url,
            model: model,
            anthropic_format: @config.anthropic_format?,
            api_format: @config.api_format,
            read_timeout: MEMORY_PICKER_READ_TIMEOUT
          )
        end
      end

      private def memory_picker_prompt(message, visible)
        <<~PROMPT
          #{load_memories_meta(limit: MEMORY_PICKER_LISTING_LIMIT)}

          Previous assistant reply (excerpt):
          #{previous_reply_excerpt(last_assistant_reply_text(visible))}

          User message:
          #{message[0, MEMORY_PICKER_USER_CHARS]}
        PROMPT
      end

      # Long replies open with the conclusion but close with the question the
      # user is answering, so keep both ends.
      private def previous_reply_excerpt(text)
        return "(none)" if text.empty?

        limit = MEMORY_PICKER_PREV_REPLY_CHARS
        return text if text.length <= limit

        half = limit / 2
        "#{text[0, half]}\n...\n#{text[-half, half]}"
      end

      private def parse_memory_picker_reply(text)
        json = begin
          JSON.parse(text)
        rescue JSON::ParserError
          match = text.match(/\{.*\}/m)
          match ? (JSON.parse(match[0]) rescue nil) : nil
        end
        files = json.is_a?(Hash) ? json["files"] : nil
        files.is_a?(Array) ? files.map(&:to_s) : []
      end

      # Bare filename that exists in the memories dir; rejects hallucinated
      # names and any path components.
      private def memory_file_name?(name)
        name.end_with?(".md") && File.basename(name) == name &&
          File.file?(File.join(memories_base_dir, name))
      end

      private def last_assistant_reply_text(visible)
        msg = visible.reverse.find { |m| m[:role] == "assistant" && !m[:content].to_s.strip.empty? }
        return "" unless msg

        content = msg[:content]
        text = if content.is_a?(Array)
          content.map { |b| b.is_a?(Hash) ? (b[:text] || b["text"]).to_s : "" }.join("\n")
        else
          content.to_s
        end
        text.strip
      end

      private def build_memory_reminder(names)
        parts = [
          "<system-reminder>",
          "Relevant long-term memories (auto-selected from ~/.clacky/memories/). " \
          "Apply them where they fit; the user's current instructions take precedence.",
          ""
        ]
        names.each do |name|
          path = File.join(memories_base_dir, name)
          mtime = File.mtime(path)
          parts << "## #{name} (last updated #{mtime.strftime("%Y-%m-%d")})"
          parts << memory_inject_body(path)
          age_days = ((Time.now - mtime) / 86_400).floor
          if age_days > MEMORY_INJECT_STALE_DAYS
            parts << "(This memory is #{age_days} days old; verify it against the current state before relying on it.)"
          end
          parts << ""
        end
        parts << "</system-reminder>"
        parts.join("\n")
      end

      private def memory_inject_body(path)
        body = File.read(path, encoding: "UTF-8").sub(/\A---\n.*?\n---\n*/m, "").strip
        return body if body.bytesize <= MEMORY_INJECT_FILE_BYTES

        "#{body.byteslice(0, MEMORY_INJECT_FILE_BYTES).scrub("")}\n...(truncated; read #{path} for the rest)"
      end
    end
  end
end
