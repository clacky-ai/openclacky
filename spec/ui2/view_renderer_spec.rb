# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/view_renderer"

RSpec.describe Clacky::UI2::ViewRenderer do
  let(:renderer) { described_class.new }

  describe "#render_user_message" do
    it "renders user message with symbol" do
      result = renderer.render_user_message("Hello")
      expect(result).to include("[>>]")
      expect(result).to include("Hello")
    end

    it "includes timestamp when provided" do
      time = Time.now
      result = renderer.render_user_message("Hello", timestamp: time)
      expect(result).to match(/\[\d{2}:\d{2}:\d{2}\]/)
    end
  end

  describe "#render_assistant_message" do
    it "renders assistant message with symbol" do
      result = renderer.render_assistant_message("World")
      expect(result).to include("[<<]")
      expect(result).to include("World")
    end

    it "returns empty string for nil content" do
      result = renderer.render_assistant_message(nil)
      expect(result).to eq("")
    end
  end

  describe "#render_tool_call" do
    it "renders tool call with name and description" do
      result = renderer.render_tool_call(
        tool_name: "file_reader",
        formatted_call: "file_reader(path: 'test.rb')"
      )
      expect(result).to include("[=>]")
      expect(result).to include("file_reader")
    end
  end

  describe "#render_tool_result" do
    it "renders tool result" do
      result = renderer.render_tool_result(result: "Success")
      expect(result).to include("[<=]")
      expect(result).to include("Success")
    end
  end

  describe "#render_tool_error" do
    it "renders tool error" do
      result = renderer.render_tool_error(error: "File not found")
      expect(result).to include("[XX]")
      expect(result).to include("Error")
      expect(result).to include("File not found")
    end
  end

  describe "#render_status" do
    it "renders status with iteration and cost" do
      result = renderer.render_status(iteration: 5, cost: 0.1234)
      expect(result).to include("Iter")
      expect(result).to include("5")
      expect(result).to include("Cost")
      expect(result).to include("0.1234")
    end

    it "renders status with tasks progress" do
      result = renderer.render_status(tasks_completed: 3, tasks_total: 10)
      expect(result).to include("Tasks")
      expect(result).to include("3/10")
    end

    it "renders custom message" do
      result = renderer.render_status(message: "Processing...")
      expect(result).to include("Processing...")
    end
  end

  describe "#render_thinking" do
    it "renders thinking indicator" do
      result = renderer.render_thinking
      expect(result).to include("[..]")
      expect(result).to include("Thinking")
    end
  end

  describe "#render_success" do
    it "renders success message" do
      result = renderer.render_success("Operation completed")
      expect(result).to include("[OK]")
      expect(result).to include("Operation completed")
    end
  end

  describe "#render_error" do
    it "renders error message" do
      result = renderer.render_error("Something went wrong")
      expect(result).to include("[ER]")
      expect(result).to include("Something went wrong")
    end
  end

  describe "#render_warning" do
    it "renders warning message" do
      result = renderer.render_warning("Be careful")
      expect(result).to include("[!!]")
      expect(result).to include("Be careful")
    end
  end

  describe "#render" do
    it "delegates to message component" do
      result = renderer.render(:message, { role: "user", content: "Test" })
      expect(result).to include("Test")
    end

    it "delegates to tool component" do
      result = renderer.render(:tool, { type: :call, tool_name: "test", formatted_call: "test()" })
      expect(result).to include("test")
    end

    it "raises error for unknown component type" do
      expect {
        renderer.render(:unknown, {})
      }.to raise_error(ArgumentError, /Unknown component type/)
    end
  end
end
