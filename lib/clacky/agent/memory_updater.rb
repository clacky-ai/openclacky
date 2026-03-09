# frozen_string_literal: true

module Clacky
  class Agent
    # Long-term memory update functionality
    # Triggered at the end of a session to persist important knowledge.
    #
    # The LLM decides:
    #   - Which topics were discussed
    #   - Which memory files to update or create
    #   - How to merge new info with existing content
    #   - What to drop to stay within the per-file token limit
    #
    # Trigger condition:
    #   - Iteration count >= MEMORY_UPDATE_MIN_ITERATIONS (avoids trivial tasks like commits)
    module MemoryUpdater
      # Minimum LLM iterations for this task before triggering memory update.
      # Set high enough to skip short utility tasks (commit, deploy, etc.)
      MEMORY_UPDATE_MIN_ITERATIONS = 10

      MEMORIES_DIR = File.expand_path("~/.clacky/memories")

      # Check if memory update should be triggered for this task.
      # Only triggers when the task had enough LLM iterations,
      # skipping short utility tasks (e.g. commit, deploy).
      # @return [Boolean]
      def should_update_memory?
        return false unless memory_update_enabled?

        task_iterations = @iterations - (@task_start_iterations || 0)
        task_iterations >= MEMORY_UPDATE_MIN_ITERATIONS
      end

      # Inject memory update prompt into @messages so the main agent loop handles it.
      # Builds the prompt dynamically, injecting the current memory file list so the
      # LLM doesn't need to scan the directory itself.
      # Returns true if prompt was injected, false otherwise.
      def inject_memory_prompt!
        return false unless should_update_memory?
        return false if @memory_prompt_injected

        @memory_prompt_injected = true
        @ui&.show_info("Updating long-term memory...")

        @messages << {
          role: "user",
          content: build_memory_update_prompt,
          system_injected: true,
          memory_update: true
        }

        true
      end

      # Clean up memory update messages from conversation history after loop ends.
      # Call this once after the main loop finishes.
      def cleanup_memory_messages
        return unless @memory_prompt_injected

        @messages.reject! { |m| m[:memory_update] }
        @memory_prompt_injected = false
        @ui&.show_info("Memory updated.")
      end

      private def memory_update_enabled?
        # Check config flag; default to true if not set
        return true unless @config.respond_to?(:memory_update_enabled)

        @config.memory_update_enabled != false
      end

      # Build the memory update prompt with the current memory file list injected.
      # @return [String]
      private def build_memory_update_prompt
        today = Time.now.strftime("%Y-%m-%d")
        meta  = load_memories_meta

        <<~PROMPT
          ═══════════════════════════════════════════════════════════════
          MEMORY UPDATE MODE
          ═══════════════════════════════════════════════════════════════
          The conversation above has ended. You are now in MEMORY UPDATE MODE.

          Your task: Persist important knowledge from this session into long-term memory.

          ## FIRST: Decide if anything is worth remembering

          Scan the conversation above. Ask yourself: did this session contain any of the following?
          - Important decisions (technical, product, process)
          - New concepts or context introduced by the user
          - Corrections to previous understanding
          - User preferences or working style observations

          If the session was purely mechanical (e.g. running commits, deploying, formatting code, running tests),
          respond immediately with: "No memory updates needed." and STOP — do NOT read any files.

          ## Existing Memory Files (pre-loaded — do NOT re-scan the directory)

          #{meta}

          Each file has YAML frontmatter:
          ```
          ---
          topic: <topic name>
          description: <one-line description>
          updated_at: <YYYY-MM-DD>
          ---
          <content in concise Markdown>
          ```

          ## Steps (only if content is worth memorizing)

          For each relevant topic from this session:
            a. If a matching file exists → read it using `file_reader(path: "~/.clacky/memories/<filename>")`, then write an updated version (merge new + old, drop stale)
            b. If no matching file → create a new one at `~/.clacky/memories/<new-filename>.md`
          Use the `write` tool to save each file. Do NOT use `safe_shell` or `file_reader` to list the directory.

          ## Hard constraints (CRITICAL)
          - Each file MUST stay under 4000 characters of content (after the frontmatter)
          - If merging would exceed this limit, remove the least important information
          - Write concise, factual Markdown — no fluff
          - Update `updated_at` to today's date: #{today}
          - Only write files for topics that genuinely appeared in this conversation
          - If nothing worth memorizing occurred, do nothing and respond: "No memory updates needed."

          Begin now.
        PROMPT
      end
    end
  end
end
