# frozen_string_literal: true

RSpec.describe Clacky::Tools::AskUser do
  let(:tool) { described_class.new }

  describe ".normalize_questions" do
    it "wraps the single-question shorthand" do
      list = described_class.normalize_questions(question: "Which DB?", options: %w[SQLite Postgres])

      expect(list.size).to eq(1)
      expect(list.first[:question]).to eq("Which DB?")
      expect(list.first[:options]).to eq(%w[SQLite Postgres])
      expect(list.first[:multi]).to be false
    end

    it "accepts string keys" do
      list = described_class.normalize_questions("question" => "Which DB?", "options" => ["SQLite"])

      expect(list.first[:question]).to eq("Which DB?")
      expect(list.first[:options]).to eq(["SQLite"])
    end

    it "normalizes a multi-question payload" do
      list = described_class.normalize_questions(
        questions: [
          { question: "Which DB?", options: %w[SQLite Postgres], recommended: 1 },
          { question: "Which features?", options: %w[auth billing], multi: true }
        ]
      )

      expect(list.size).to eq(2)
      expect(list[0][:recommended]).to eq(1)
      expect(list[1][:multi]).to be true
    end

    it "marks an option-less question as free text" do
      list = described_class.normalize_questions(questions: [{ question: "What is the name?" }])

      expect(list.first[:options]).to eq([])
      expect(list.first[:allow_free_text]).to be true
    end

    it "drops entries with blank or missing question text" do
      list = described_class.normalize_questions(
        questions: [{ question: "  " }, { options: ["a"] }, { question: "Real?" }]
      )

      expect(list.map { |q| q[:question] }).to eq(["Real?"])
    end

    it "falls back to the shorthand when questions is malformed" do
      list = described_class.normalize_questions(questions: "not-an-array", question: "Fallback?")

      expect(list.map { |q| q[:question] }).to eq(["Fallback?"])
    end

    it "returns an empty list when nothing is usable" do
      expect(described_class.normalize_questions({})).to eq([])
      expect(described_class.normalize_questions(nil)).to eq([])
    end

    it "discards an out-of-range recommended index" do
      list = described_class.normalize_questions(
        questions: [{ question: "Pick", options: %w[a b], recommended: 7 }]
      )

      expect(list.first[:recommended]).to be_nil
    end

    it "coerces a stringified recommended index" do
      list = described_class.normalize_questions(
        questions: [{ question: "Pick", options: %w[a b], recommended: "1" }]
      )

      expect(list.first[:recommended]).to eq(1)
    end

    it "coerces stringified booleans emitted by some models" do
      list = described_class.normalize_questions(
        questions: [{ question: "Pick", options: %w[a b], multi: "true" }]
      )

      expect(list.first[:multi]).to be true
    end

    it "drops blank options" do
      list = described_class.normalize_questions(
        questions: [{ question: "Pick", options: ["a", "  ", nil, "b"] }]
      )

      expect(list.first[:options]).to eq(%w[a b])
    end
  end

  describe ".feedback_tool?" do
    it "matches both the current and retired tool names" do
      expect(described_class.feedback_tool?("ask_user")).to be true
      expect(described_class.feedback_tool?("request_user_feedback")).to be true
      expect(described_class.feedback_tool?("terminal")).to be false
    end
  end

  describe "#execute" do
    it "renders a single question" do
      result = tool.execute(question: "What color scheme should I use?")

      expect(result[:success]).to be true
      expect(result[:message]).to include("**Question:** What color scheme should I use?")
      expect(result[:awaiting_feedback]).to be true
    end

    it "includes context when provided" do
      result = tool.execute(question: "SQLite or Postgres?", context: "Choosing a database")

      expect(result[:message]).to include("**Context:** Choosing a database")
    end

    it "numbers options" do
      result = tool.execute(question: "Which framework?", options: %w[Rails Sinatra])

      expect(result[:message]).to include("1. Rails")
      expect(result[:message]).to include("2. Sinatra")
    end

    it "numbers each question when several are asked" do
      result = tool.execute(
        questions: [
          { question: "Which DB?", options: ["SQLite"] },
          { question: "Which host?", options: ["Fly"] }
        ]
      )

      expect(result[:message]).to include("**Question 1:** Which DB?")
      expect(result[:message]).to include("**Question 2:** Which host?")
      expect(result[:awaiting_feedback]).to be true
    end

    it "marks the recommended option" do
      result = tool.execute(questions: [{ question: "Pick", options: %w[a b], recommended: 1 }])

      expect(result[:message]).to match(/2\. b.*recommended/)
    end

    it "labels multi-select questions" do
      result = tool.execute(questions: [{ question: "Pick", options: %w[a b], multi: true }])

      expect(result[:message]).to include("**Options (choose any):**")
    end

    it "offers a free-text choice when allowed" do
      result = tool.execute(
        questions: [{ question: "Pick", options: %w[a b], allow_free_text: true }]
      )

      expect(result[:message]).to include("3. Other")
    end

    it "fails without stalling the agent when no question is usable" do
      result = tool.execute(questions: [{ options: ["a"] }])

      expect(result[:success]).to be false
      expect(result[:awaiting_feedback]).to be_nil
      expect(result[:error]).to include("at least one question")
    end
  end

  describe "#format_call" do
    it "previews a single question" do
      expect(tool.format_call(question: "What color?")).to eq('ask_user("What color?")')
    end

    it "truncates a long question" do
      formatted = tool.format_call(question: "A" * 100)

      expect(formatted).to include("...")
      expect(formatted.length).to be < 100
    end

    it "counts multiple questions" do
      formatted = tool.format_call(questions: [{ question: "a" }, { question: "b" }])

      expect(formatted).to eq("ask_user(2 questions)")
    end
  end

  describe "#to_function_definition" do
    let(:definition) { tool.to_function_definition }

    it "exposes the tool as ask_user" do
      expect(definition[:function][:name]).to eq("ask_user")
    end

    it "declares questions as an array so double-serialized payloads get unwrapped" do
      questions = definition[:function][:parameters][:properties][:questions]

      expect(questions[:type]).to eq("array")
      expect(questions[:items][:required]).to eq(["question"])
    end

    it "keeps per-question options a flat string array" do
      options = definition[:function][:parameters][:properties][:questions][:items][:properties][:options]

      expect(options[:type]).to eq("array")
      expect(options[:items][:type]).to eq("string")
    end

    it "requires nothing at the top level so a partial payload still parses" do
      expect(definition[:function][:parameters][:required]).to be_nil
    end
  end
end
