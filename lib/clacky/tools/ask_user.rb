# frozen_string_literal: true

module Clacky
  module Tools
    class AskUser < Base
      self.tool_name = "ask_user"
      self.tool_description = <<~DESC
        Ask the user to choose when you cannot infer the answer and guessing would waste work.

        Every question must have `options` — this tool is for choices, not open prompts.
        Need freeform input (a path, a name)? Just ask in your reply instead.
        Each option must be complete enough to act on directly. Never write an "Other"
        option — set `allow_free_text` and the UI adds one.

        Batch related questions into one call; use separate calls for unrelated topics.
        After calling, STOP and wait for the answer.
      DESC

      self.tool_parameters = {
        type: "object",
        properties: {
          questions: {
            type: "array",
            description: "Questions to ask in one round-trip. Use this, or the `question` shorthand.",
            items: {
              type: "object",
              properties: {
                question: {
                  type: "string",
                  description: "The question text."
                },
                description: {
                  type: "string",
                  description: "Optional detail shown under the question."
                },
                options: {
                  type: "array",
                  items: { type: "string" },
                  description: "Selectable answers, each specific enough to act on."
                },
                multi: {
                  type: "boolean",
                  description: "True if several options may be picked. Default false."
                },
                allow_free_text: {
                  type: "boolean",
                  description: "True to let the user type their own answer instead."
                },
                recommended: {
                  type: "integer",
                  description: "0-based index of the option you recommend; it is pre-selected."
                }
              },
              required: ["question"]
            }
          },
          question: {
            type: "string",
            description: "Single-question shorthand."
          },
          context: {
            type: "string",
            description: "Optional background shown above the questions."
          },
          options: {
            type: "array",
            items: { type: "string" },
            description: "Options for the single-question shorthand."
          }
        }
      }

      self.tool_category = "interaction"

      # Both names route here: request_user_feedback is the retired predecessor,
      # still present in stored sessions and in skill instructions.
      TOOL_NAMES = %w[ask_user request_user_feedback].freeze

      def self.feedback_tool?(name)
        TOOL_NAMES.include?(name.to_s)
      end

      # Coerce whatever the model produced into a stable
      # [{ question:, description:, options: [String], multi:, allow_free_text:, recommended: }] shape.
      # Never raises: malformed input degrades to a plain free-form question so the
      # agent surfaces something answerable instead of stalling on a schema error.
      def self.normalize_questions(args)
        args = {} unless args.is_a?(Hash)
        raw = fetch_key(args, :questions)
        raw = [] unless raw.is_a?(Array)

        list = raw.map { |item| normalize_question(item) }.compact

        if list.empty?
          question = fetch_key(args, :question).to_s.strip
          return [] if question.empty?

          list = [normalize_question(
            question: question,
            options: fetch_key(args, :options)
          )].compact
        end

        list
      end

      def self.normalize_question(item)
        return nil unless item.is_a?(Hash)

        text = fetch_key(item, :question).to_s.strip
        return nil if text.empty?

        options = fetch_key(item, :options)
        options = [] unless options.is_a?(Array)
        options = options.map { |opt| opt.to_s.strip }.reject(&:empty?)

        recommended = fetch_key(item, :recommended)
        recommended = recommended.to_i if recommended.is_a?(Numeric) || recommended.to_s =~ /\A-?\d+\z/
        recommended = nil unless recommended.is_a?(Integer) && recommended >= 0 && recommended < options.size

        {
          question: text,
          description: fetch_key(item, :description).to_s.strip,
          options: options,
          multi: truthy?(fetch_key(item, :multi)),
          # A question with no options is free-form by definition, whatever the model said.
          allow_free_text: options.empty? || truthy?(fetch_key(item, :allow_free_text)),
          recommended: recommended
        }
      end

      def self.fetch_key(hash, key)
        return nil unless hash.is_a?(Hash)

        hash[key].nil? ? hash[key.to_s] : hash[key]
      end

      def self.truthy?(value)
        return true if value == true
        return false if value.nil? || value == false

        %w[true yes 1].include?(value.to_s.strip.downcase)
      end

      # Render questions as markdown for UIs without a native card (terminal, IM channels).
      def self.render_text(questions, context = nil)
        parts = []
        parts << "**Context:** #{context.strip}" if context && !context.to_s.strip.empty?

        multiple = questions.size > 1
        questions.each_with_index do |q, q_index|
          parts << "" unless parts.empty?
          heading = multiple ? "**Question #{q_index + 1}:** #{q[:question]}" : "**Question:** #{q[:question]}"
          parts << heading
          parts << q[:description] unless q[:description].empty?

          next if q[:options].empty?

          parts << ""
          parts << (q[:multi] ? "**Options (choose any):**" : "**Options:**")
          q[:options].each_with_index do |opt, index|
            marker = q[:recommended] == index ? " _(recommended)_" : ""
            parts << "  #{index + 1}. #{opt}#{marker}"
          end
          parts << "  #{q[:options].size + 1}. Other — type your own answer" if q[:allow_free_text]
        end

        parts.join("\n")
      end

      def execute(questions: nil, question: nil, context: nil, options: nil, working_dir: nil)
        normalized = self.class.normalize_questions(
          questions: questions, question: question, options: options
        )

        if normalized.empty?
          return {
            success: false,
            error: "ask_user requires at least one question with non-empty text."
          }
        end

        {
          success: true,
          message: self.class.render_text(normalized, context),
          awaiting_feedback: true
        }
      end

      def format_call(args)
        questions = self.class.normalize_questions(args)
        return "ask_user(...)" if questions.empty?

        if questions.size > 1
          "ask_user(#{questions.size} questions)"
        else
          text = questions.first[:question]
          preview = text.length > 60 ? "#{text[0..60]}..." : text
          "ask_user(\"#{preview}\")"
        end
      end

      def format_result(result)
        if result.is_a?(Hash) && result[:message]
          result[:message]
        else
          "Waiting for user feedback..."
        end
      end
    end
  end
end
