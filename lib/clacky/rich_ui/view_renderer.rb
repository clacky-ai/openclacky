# frozen_string_literal: true

require "json"
require "uri"
require "ruby_rich"

module Clacky
  module RichUI
    # ViewRenderer provides stateless formatting helpers extracted from
    # RichUIController.  All methods are module functions — callable as
    #   ViewRenderer.format_args(...)
    # or mixin-able via `include ViewRenderer`.
    module ViewRenderer
      module_function

      # ── Tool output formatting ──────────────────────────────────

      def format_tool_output(text, status = :done)
        marker = status == :error ? "[Error]" : "[OK]"
        color = status == :error ? :red : :green
        clean = text.to_s.sub(/\A\[(?:OK|Error)\]\s*/, "")
        "#{RubyRich::AnsiCode.color(color, true)}#{marker}#{RubyRich::AnsiCode.reset} #{clean}"
      end

      def format_args(args)
        data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
        return data.to_s unless data.is_a?(Hash) && !data.empty?

        data.map { |k, v| "#{k}: #{format_tool_value(v)}" }.join("\n")
      end

      def format_tool_value(v)
        v.is_a?(String) ? v : JSON.generate(v)
      end

      def normalize_todo(todo)
        case todo
        when Hash
          title = todo[:content] || todo["content"] || todo[:title] || todo["title"] || todo[:task] || todo["task"]
          status = todo[:status] || todo["status"] || :pending
          { label: title.to_s, title: title.to_s, status: status.to_sym }
        else
          { label: todo.to_s, title: todo.to_s, status: :pending }
        end
      end

      # ── Tool activity label helpers ─────────────────────────────

      def tool_activity_label(name, args)
        tool_name = name.to_s
        data = normalize_tool_args(args)

        case tool_name
        when "web_search"
          query = data["query"].to_s
          return tool_name if query.empty?

          %(web_search("#{escape_tool_label(truncate_tool_label(query))}"))
        when "web_fetch"
          url = data["url"].to_s
          return tool_name if url.empty?

          "web_fetch(#{truncate_tool_label(tool_url_host(url))})"
        else
          compact = compact_tool_arg(data)
          compact ? "#{tool_name}(#{compact})" : tool_name
        end
      end

      def normalize_tool_args(args)
        parsed = if args.is_a?(String)
          JSON.parse(args)
        else
          args
        end
        return {} unless parsed.is_a?(Hash)

        parsed.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
      rescue JSON::ParserError
        {}
      end

      def compact_tool_arg(data)
        key = %w[query url path file command pattern task].find { |candidate| data.key?(candidate) && !data[candidate].to_s.empty? }
        return nil unless key

        value = key == "url" ? tool_url_host(data[key].to_s) : data[key].to_s
        escaped = escape_tool_label(truncate_tool_label(value))
        value.match?(/\A[\w.-]+\z/) ? escaped : %("#{escaped}")
      end

      def tool_url_host(url)
        URI.parse(url).host || url
      rescue URI::InvalidURIError
        url
      end

      def truncate_tool_label(text, limit = 40)
        chars = text.to_s.each_char.to_a
        return text.to_s if chars.length <= limit

        "#{chars.first(limit - 3).join}..."
      end

      def escape_tool_label(text)
        text.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
      end

      # ── Markdown helpers ────────────────────────────────────────

      def normalize_markdown_for_terminal(text)
        text.to_s
          .gsub(/\r\n?/, "\n")
          .gsub(/\A[ \t]*\n+/, "")
          .gsub(/\n+[ \t]*\z/, "")
      end

      def expand_ansi_multiline_spans(text)
        active = +""
        text.to_s.lines.map do |line|
          body = line.chomp
          prefix = body.start_with?("\e[") || active.empty? ? "" : active
          body.scan(/\e\[[0-9;:]*m/).each do |code|
            active = code == RubyRich::AnsiCode.reset ? +"" : code
          end
          suffix = !active.empty? && !body.end_with?(RubyRich::AnsiCode.reset) ? RubyRich::AnsiCode.reset : ""
          "#{prefix}#{body}#{suffix}"
        end.join("\n")
      end

      # ── Diff / stats helpers ────────────────────────────────────

      def parse_diff_stats(diff_text)
        adds = 0
        dels = 0
        hunks = 0
        diff_text.each_line do |line|
          adds += 1 if line.start_with?("+") && !line.start_with?("+++")
          dels += 1 if line.start_with?("-") && !line.start_with?("---")
          hunks += 1 if line.start_with?("@@")
        end
        return "" if adds.zero? && dels.zero?

        parts = []
        parts << "+#{adds}" if adds.positive?
        parts << "-#{dels}" if dels.positive?
        parts << "#{hunks} hunks" if hunks.positive?
        " (#{parts.join(", ")})"
      end

      def extract_thinking_and_content(content)
        return ["", content.to_s] if content.nil?

        thinking_parts = []
        clean = content.to_s.dup

        clean.gsub!(%r{<think(?:ing)?>\s*([\s\S]*?)\s*</think(?:ing)?>}mi) do
          thinking_parts << Regexp.last_match(1).strip
          ""
        end

        clean = clean.gsub(/\n{3,}/, "\n\n").strip
        [thinking_parts.join("\n\n"), clean]
      end

      # ── Config / dialog helpers ─────────────────────────────────

      def mask_api_key(api_key)
        key = api_key.to_s
        return "not set" if key.empty?

        "#{key[0..5]}...#{key[-4..]}"
      end

      def config_menu_choices(current_config)
        choices = current_config.models.each_with_index.map do |model, index|
          type_badge = case model["type"]
                       when "default" then "[default] "
                       when "lite" then "[lite] "
                       else ""
                       end
          {
            label: "#{type_badge}#{model["model"] || "unnamed"} (#{mask_api_key(model["api_key"])})",
            value: { action: :switch, model_id: model["id"] },
            current: index == current_config.current_model_index
          }
        end

        choices + [
          { label: "─" * 50, disabled: true },
          { label: "[+] Add New Model", value: { action: :add } },
          { label: "[*] Edit Current Model", value: { action: :edit } },
          (current_config.models.length > 1 ? { label: "[-] Delete Model", value: { action: :delete } } : nil),
          { label: "[X] Close", value: { action: :close } }
        ].compact
      end

      def config_initial_selection(choices)
        choices.index { |choice| choice[:current] } || choices.index { |choice| !choice[:disabled] } || 0
      end

      def merge_model_form_values(result, model:, default_model:, default_base_url:)
        {
          api_key: result[:api_key].to_s.empty? ? model["api_key"] : result[:api_key],
          model: result[:model].to_s.empty? ? (model["model"] || default_model) : result[:model],
          base_url: result[:base_url].to_s.empty? ? (model["base_url"] || default_base_url) : result[:base_url]
        }
      end

      def validate_model_form(values, is_new:, existing_model:, test_callback:)
        if is_new
          return { success: false, error: "API Key is required for new model" } if values[:api_key].to_s.empty?
          return { success: false, error: "Model name is required" } if values[:model].to_s.empty?
          return { success: false, error: "Base URL is required" } if values[:base_url].to_s.empty?
        end

        return { success: true } unless test_callback

        temp_config = Clacky::AgentConfig.new(
          models: [{
            "api_key" => values[:api_key],
            "model" => values[:model],
            "base_url" => values[:base_url],
            "anthropic_format" => existing_model["anthropic_format"]
          }],
          current_model_index: 0
        )
        test_callback.call(temp_config)
      end

      # ── Approval helpers ────────────────────────────────────────

      def parse_tool_info(message)
        return [nil, {}] unless message

        tool_name = message[/\A\w+/]&.downcase
        params = {}

        case tool_name
        when "edit", "write"
          path = message[/\((.+?)\)/, 1]
          params[:path] = path if path
        when "terminal", "shell", "exec"
          cmd = message[/"(.+?)"/, 1]
          params[:command] = cmd if cmd
        when "web_search", "web_fetch"
          params[:query] = message[(message.index("(")&.+(1) || 0)..]&.chomp(")")&.strip
        when "execute", "run"
          params[:command] = message[(message.index("(")&.+(1) || 0)..]&.chomp(")")&.strip
        end

        params.reject! { |_, v| v.to_s.empty? }
        [tool_name, params]
      end

      def tool_risk_level(tool_name)
        case tool_name
        when "read", "grep", "list", "search", "web_search", "web_fetch", "fetch_url"
          :low
        when "edit", "write", "patch", "apply_patch"
          :medium
        when "shell", "terminal", "exec", "execute", "run"
          :high
        when "install", "remove", "delete", "rm", "force"
          :critical
        else
          :medium
        end
      end

      def tool_category(tool_name)
        case tool_name
        when "read", "write", "edit", "patch", "apply_patch", "grep", "list"
          :file
        when "shell", "terminal", "exec", "execute", "run"
          :shell
        when "web_search", "web_fetch", "fetch_url"
          :network
        when "install", "billing", "payment"
          :paid
        else
          :file
        end
      end

      def build_fingerprint(tool_name, params)
        "#{tool_name}:#{params.sort.to_s}"
      end
    end
  end
end
