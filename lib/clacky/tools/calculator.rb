# frozen_string_literal: true

require_relative "base"

module Clacky
  module Tools
    class Calculator < Base
      self.tool_name = "calculator"
      self.tool_description = "Execute mathematical calculations safely"
      self.tool_category = "computation"
      self.tool_parameters = {
        type: "object",
        properties: {
          expression: {
            type: "string",
            description: "Mathematical expression to evaluate (e.g., '(123 + 456) * 789')"
          }
        },
        required: ["expression"]
      }

      def execute(expression:)
        # 安全的数学计算 - 只允许数字和基本运算符
        sanitized = expression.gsub(/[^\d+\-*\/().\s]/, "")

        if sanitized != expression
          return {
            error: "Invalid expression: contains non-mathematical characters",
            result: nil
          }
        end

        begin
          # 使用 Ruby 的 eval，但只在清理后的表达式上
          result = eval(sanitized)
          {
            expression: expression,
            result: result.to_s,
            error: nil
          }
        rescue StandardError => e
          {
            expression: expression,
            result: nil,
            error: "Calculation error: #{e.message}"
          }
        end
      end
    end
  end
end
