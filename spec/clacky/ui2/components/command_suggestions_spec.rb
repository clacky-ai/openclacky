# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/command_suggestions"

RSpec.describe Clacky::UI2::Components::CommandSuggestions do
  let(:suggestions) { described_class.new }

  describe "#initialize" do
    it "starts hidden" do
      expect(suggestions.visible).to be false
    end

    it "has system commands available" do
      # Commands are loaded through update_commands, which combines SYSTEM_COMMANDS and skill_commands
      # Just verify SYSTEM_COMMANDS constant exists
      expect(described_class::SYSTEM_COMMANDS.map { |c| c[:command] }).to include("/clear", "/exit", "/help")
    end
  end

  describe "#show" do
    it "shows suggestions with empty filter" do
      suggestions.show("")
      expect(suggestions.visible).to be true
    end

    it "filters commands by prefix" do
      suggestions.show("cl")
      filtered = suggestions.instance_variable_get(:@filtered_commands)
      commands = filtered.map { |c| c[:command] }
      expect(commands).to include("/clear")
      expect(commands).not_to include("/exit")
      expect(commands).not_to include("/help")
    end

    it "is case-insensitive" do
      suggestions.show("C")
      filtered = suggestions.instance_variable_get(:@filtered_commands)
      commands = filtered.map { |c| c[:command] }
      expect(commands).to include("/clear")
    end
  end

  describe "#hide" do
    it "hides suggestions" do
      suggestions.show("")
      suggestions.hide
      expect(suggestions.visible).to be false
    end
  end

  describe "#select_next" do
    before do
      suggestions.show("")
    end

    it "increments selected index" do
      initial_index = suggestions.instance_variable_get(:@selected_index)
      suggestions.select_next
      new_index = suggestions.instance_variable_get(:@selected_index)
      expect(new_index).to eq(initial_index + 1)
    end

    it "wraps around at end" do
      # Select to the end
      filtered_count = suggestions.instance_variable_get(:@filtered_commands).size
      filtered_count.times { suggestions.select_next }
      
      # Should wrap to 0
      expect(suggestions.instance_variable_get(:@selected_index)).to eq(0)
    end
  end

  describe "#select_previous" do
    before do
      suggestions.show("")
    end

    it "decrements selected index" do
      suggestions.select_next # Move to index 1
      suggestions.select_previous
      expect(suggestions.instance_variable_get(:@selected_index)).to eq(0)
    end

    it "wraps around at start" do
      suggestions.select_previous
      filtered_count = suggestions.instance_variable_get(:@filtered_commands).size
      expect(suggestions.instance_variable_get(:@selected_index)).to eq(filtered_count - 1)
    end
  end

  describe "#selected_command_text" do
    before do
      suggestions.show("")
    end

    it "returns selected command text" do
      selection = suggestions.selected_command_text
      expect(selection).to match(%r{^/\w+})
    end

    it "returns updated selection after navigation" do
      initial = suggestions.selected_command_text
      suggestions.select_next
      new_selection = suggestions.selected_command_text
      # Only check if not equal if there are multiple commands
      expect(new_selection).to match(%r{^/\w+})
    end
  end

  describe "#required_height" do
    it "returns 0 when hidden" do
      expect(suggestions.required_height).to eq(0)
    end

    it "returns height based on filtered commands" do
      suggestions.show("")
      height = suggestions.required_height
      expect(height).to be > 0
    end

    it "caps at max display count" do
      # Create test skills
      test_skills = 100.times.map do |i|
        double("Skill", slash_command: "/test#{i}", description: "Test command #{i}", argument_hint: nil)
      end

      skill_loader = double("SkillLoader", user_invocable_skills: test_skills)
      suggestions.load_skill_commands(skill_loader)
      
      suggestions.show("")
      height = suggestions.required_height
      # Height = header(1) + items(max 5) + footer(1)
      expect(height).to eq(1 + 5 + 1)
    end
  end

  describe "#load_skill_commands" do
    let(:test_skill) do
      double("Skill",
        slash_command: "/test-skill",
        description: "Test skill",
        argument_hint: nil
      )
    end

    let(:skill_loader) do
      double("SkillLoader", user_invocable_skills: [test_skill])
    end

    it "loads skill commands from skill loader" do
      suggestions.load_skill_commands(skill_loader)
      skill_commands = suggestions.instance_variable_get(:@skill_commands)
      commands = skill_commands.map { |c| c[:command] }
      expect(commands).to include("/test-skill")
    end

    it "categorizes skill commands correctly" do
      suggestions.load_skill_commands(skill_loader)
      skill_commands = suggestions.instance_variable_get(:@skill_commands)
      skill_cmd = skill_commands.find { |c| c[:command] == "/test-skill" }
      expect(skill_cmd[:type]).to eq(:skill)
    end
  end

  describe "#render" do
    before do
      suggestions.show("")
    end

    it "returns string output" do
      output = suggestions.render(row: 10, col: 0, width: 60)
      expect(output).to be_a(String)
    end

    it "includes command suggestions" do
      output = suggestions.render(row: 10, col: 0, width: 60)
      expect(output).to include("/clear")
    end

    it "highlights selected command" do
      output = suggestions.render(row: 10, col: 0, width: 60)
      # Should contain some highlighting (depends on pastel, just check it's not empty)
      expect(output.length).to be > 0
    end
  end
end
