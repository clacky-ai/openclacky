# frozen_string_literal: true

RSpec.describe Clacky::Tools::Calculator do
  let(:tool) { described_class.new }

  describe "#execute" do
    it "calculates simple addition" do
      result = tool.execute(expression: "2 + 2")

      expect(result[:result]).to eq("4")
      expect(result[:error]).to be_nil
    end

    it "calculates complex expressions" do
      result = tool.execute(expression: "(10 + 5) * 2")

      expect(result[:result]).to eq("30")
      expect(result[:error]).to be_nil
    end

    it "handles floating point numbers" do
      result = tool.execute(expression: "10.5 + 2.3")

      expect(result[:result]).to eq("12.8")
      expect(result[:error]).to be_nil
    end

    it "rejects expressions with invalid characters" do
      result = tool.execute(expression: "2 + 2; system('ls')")

      expect(result[:error]).to include("Invalid expression")
      expect(result[:result]).to be_nil
    end

    it "handles division by zero" do
      result = tool.execute(expression: "10 / 0")

      expect(result[:error]).to include("Calculation error")
      expect(result[:result]).to be_nil
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("calculator")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters]).to have_key(:properties)
      expect(definition[:function][:parameters][:required]).to include("expression")
    end
  end
end
