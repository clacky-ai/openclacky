# frozen_string_literal: true

require "json"

module Clacky
  module Utils
    class ArgumentsParser
      # Parse and validate tool call arguments with JSON repair capability
      def self.parse_and_validate(call, tool_registry)
        # 1. Try standard parsing
        begin
          args = JSON.parse(call[:arguments], symbolize_names: true)
          
          # Check if any key contains XML tags (< or >) indicating contamination
          # Even though JSON.parse succeeded, the keys might be malformed
          has_xml_contamination = args.keys.any? { |k| k.to_s.include?('<') || k.to_s.include?('>') }
          
          if has_xml_contamination
            # Force repair even though JSON.parse succeeded
            raise JSON::ParserError.new("Keys contain XML contamination")
          end
          
          return validate_required_params(call, args, tool_registry)
        rescue JSON::ParserError => e
          # Continue to repair
        end

        # 2. Try simple repair
        repaired = repair_json(call[:arguments])

        begin
          args = JSON.parse(repaired, symbolize_names: true)
          return validate_required_params(call, args, tool_registry)
        rescue JSON::ParserError, MissingRequiredParamsError => e
          # 3. Repair failed or missing params, return helpful error
          raise_helpful_error(call, tool_registry, e)
        end
      end


      # Simple JSON repair: complete brackets and quotes, and remove XML contamination
      def self.repair_json(json_str)

        result = json_str.strip
        # Step 0: Convert literal \n (backslash+n) to real newlines
        result = result.gsub(/\\n/, "\n")
        # Step 0.5: Unescape quotes in JSON keys and values (\" -> ")
        # This handles cases like {"end_line\":550 or name=\"path\"
        result = result.gsub(/\\"/, '"')
        # Step 1: Remove XML-style parameter tags that Claude might mix in
        # Pattern 1: </parameter> closing tags - remove completely
        result = result.gsub(/<\/parameter>/, '')

        # Pattern 2: <parameter name="key"> or <parameter name="key": opening tags -> convert to JSON key
        # Example: \n<parameter name="end_line"> 330 -> , "end_line": 330
        # Also handles: \n<parameter name="end_line": 330 -> , "end_line": 330
        # result = result.gsub(/<parameter\s+name="([^"\\]+)":\s*/) { |match| ", \"#{$1}\": " }
        # result = result.gsub(/<parameter\s+name="([^"\\]+)">/) { |match| ", \"#{$1}\":" }
        result = result.gsub(/<parameter\s+name=\\?"([^"\\]+)\\?"[>:]?\s*/) { |match| ", \"#{$1}\": " }

        # Pattern 3: Remove any remaining XML-like tags
        result = result.gsub(/<[^>]+>/, '')

        # Step 2: Clean up newlines with commas
        # Example: 315\n, "end_line" -> 315, "end_line"
        result = result.gsub(/\n\s*,/, ',')
        result = result.gsub(/\n,/, ',')
        result = result.gsub(/,\s*\n/, ',')

        # Step 3: Clean up formatting issues
        # Remove multiple consecutive commas
        result = result.gsub(/,+/, ',')
        # Remove trailing commas before closing braces/brackets
        result = result.gsub(/,\s*}/, '}')
        result = result.gsub(/,\s*\]/, ']')
        # Remove leading commas after opening braces/brackets
        result = result.gsub(/\{\s*,/, '{')
        result = result.gsub(/\[\s*,/, '[')

        # Step 4: Complete unclosed strings
        result += '"' if result.count('"').odd?

        # Step 5: Close unclosed braces/brackets in the order they were opened.
        # Tracks a delimiter stack so truncated nested arrays (e.g. a cut-off
        # `questions` list) are closed as `}]}` rather than `}}}`.
        stack = []
        in_string = false
        escaped = false
        result.each_char do |c|
          if escaped
            escaped = false
            next
          end

          if c == '\\'
            escaped = true if in_string
            next
          end

          if c == '"'
            in_string = !in_string
            next
          end

          next if in_string

          case c
          when '{' then stack.push('}')
          when '[' then stack.push(']')
          when '}', ']' then stack.pop if stack.last == c
          end
        end
        result += stack.reverse.join

        result
      end

      # Undo one layer of accidental double-serialization, guided by the tool's
      # parameter schema.
      #
      # Some LLMs (e.g. glm-5.2) emit array/object parameters as a JSON *string*
      # (e.g. {"task":"[\"a\",\"b\"]"}) instead of a native JSON value. JSON.parse
      # only strips the outer layer, so such values arrive here as a literal
      # String and break downstream tools that expect an Array/Hash.
      #
      # To stay safe we rely on the declared schema type instead of a blind
      # "looks like JSON" heuristic:
      #   - a parameter declared `type: "string"` is NEVER parsed, so a value
      #     that merely happens to be valid JSON text (file content, a code
      #     snippet, a JSON blob to be written) is preserved verbatim;
      #   - a parameter declared `type: "array"`/`"object"` that still arrives
      #     as a String is unwrapped exactly once;
      #   - additionally, when a concrete type IS declared, the parsed result
      #     must match it (an array-typed param that receives a JSON object
      #     string is left untouched rather than silently coerced to a Hash);
      #   - a parameter with no declared `type` (e.g. flexible params such as
      #     todo_manager's task/id, which may be a scalar or a list) falls back
      #     to a conservative heuristic: unwrap only if the stripped value
      #     starts with "["/"{" and parses cleanly.
      # Strings that fail JSON.parse are always left untouched.
      def self.undouble_serialize_args(args, properties = {})
        args.to_h do |key, value|
          expected = schema_type(properties, key)
          # Explicit string params: never unwrap (protects content / code / JSON text).
          next [key, value] if expected == "string"
          # Scalar-typed params (integer/number/boolean): no JSON shape to recover.
          next [key, value] if expected && expected != "array" && expected != "object"
          # For array/object/untyped params, only unwrap a String that looks like JSON.
          next [key, value] unless value.is_a?(String)
          stripped = value.strip
          next [key, value] unless stripped.start_with?("[") || stripped.start_with?("{")
          begin
            # symbolize_names keeps unwrapped Hash keys consistent with the
            # outer JSON.parse(call[:arguments], symbolize_names: true).
            parsed = JSON.parse(value, symbolize_names: true)
            # Type-match guard: if the schema declares a concrete type, the
            # parsed value must match it. Prevents silently turning a Hash into
            # an Array (or vice-versa) when an array-typed param receives a
            # JSON object string, etc.
            if expected == "array" && !parsed.is_a?(Array)
              next [key, value]
            elsif expected == "object" && !parsed.is_a?(Hash)
              next [key, value]
            end
            [key, parsed]
          rescue JSON::ParserError
            [key, value]
          end
        end
      end

      # Look up a parameter's declared JSON-Schema type, tolerating string/symbol
      # keys in both +properties+ and the per-param spec hash.
      def self.schema_type(properties, key)
        spec = properties[key] || properties[key.to_s] || properties[key.to_sym]
        return nil unless spec.is_a?(Hash)
        spec[:type] || spec["type"]
      end

      # Validate required parameters and filter unknown parameters
      def self.validate_required_params(call, args, tool_registry)
        tool = tool_registry.get(call[:name])
        required = tool.parameters&.dig(:required) || []
        properties = tool.parameters&.dig(:properties) || {}

        # Undo accidental double-serialization BEFORE filtering, using the schema
        # so that parameters declared as "string" are never touched.
        args = undouble_serialize_args(args, properties)

        missing = required.reject { |param|
          args.key?(param.to_sym) || args.key?(param.to_s)
        }

        if missing.any?
          raise MissingRequiredParamsError.new(call[:name], missing, args.keys)
        end

        # Filter out unknown parameters to prevent errors when LLM sends extra arguments
        known_params = properties.keys.map(&:to_sym) + properties.keys.map(&:to_s)
        filtered_args = args.select { |key, _| known_params.include?(key) }

        filtered_args
      end

      # Generate error message with tool definition
      def self.raise_helpful_error(call, tool_registry, original_error)
        tool = tool_registry.get(call[:name])
        error_msg = build_error_message(call, tool, original_error)
        raise BadArgumentsError, error_msg
      end

      def self.build_error_message(call, tool, original_error)
        # Extract tool information
        required_params = tool.parameters&.dig(:required) || []

        # Try to parse provided parameters from incomplete JSON
        provided_params = extract_provided_params(call[:arguments])

        # Build clear error message
        msg = []
        msg << "Failed to parse arguments for tool '#{call[:name]}'."
        msg << ""
        msg << "Error: #{original_error.message}"
        msg << ""

        if provided_params.any?
          msg << "Provided parameters: #{provided_params.join(', ')}"
        else
          msg << "No valid parameters could be extracted."
        end

        msg << "Required parameters: #{required_params.join(', ')}"
        msg << ""
        msg << "Tool definition:"
        msg << format_tool_definition(tool)
        msg << ""
        msg << "Suggestions:"
        msg << "- If the parameter value is too large (e.g., large file content), consider breaking it into smaller operations"
        msg << "- Ensure all required parameters are provided"
        msg << "- Simplify complex parameter values"

        msg.join("\n")
      end

      # Extract parameter names from incomplete JSON
      def self.extract_provided_params(json_str)
        # Simple extraction: find all "key": patterns
        json_str.scan(/"(\w+)"\s*:/).flatten.uniq
      end

      # Format tool definition (concise version)
      def self.format_tool_definition(tool)
        lines = []
        lines << "  Name: #{tool.name}"
        lines << "  Description: #{tool.description}"

        params = tool.parameters
        properties = params && params[:properties]
        if properties
          lines << "  Parameters:"
          properties.each do |param, spec|
            required_mark = params[:required]&.include?(param.to_s) ? " (required)" : ""
            desc = spec.is_a?(Hash) ? spec[:description] : spec.to_s
            lines << "    - #{param}#{required_mark}: #{desc}"
          end
        end

        lines.join("\n")
      end
    end

    # Raised when tool call arguments are malformed or missing required params.
    class BadArgumentsError < StandardError; end

    # Custom exception for missing required parameters
    class MissingRequiredParamsError < BadArgumentsError
      attr_reader :tool_name, :missing_params, :provided_params

      def initialize(tool_name, missing_params, provided_params)
        @tool_name = tool_name
        @missing_params = missing_params
        @provided_params = provided_params
        super("Missing required parameters: #{missing_params.join(', ')}")
      end
    end
  end
end
