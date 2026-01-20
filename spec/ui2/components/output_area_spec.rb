# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/output_area"

RSpec.describe Clacky::UI2::Components::OutputArea do
  let(:output_area) { described_class.new(height: 10) }

  describe "#append" do
    it "adds single line to buffer" do
      output_area.append("Hello, World!")
      expect(output_area.buffer).to eq(["Hello, World!"])
    end

    it "splits multi-line content" do
      output_area.append("Line 1\nLine 2\nLine 3")
      expect(output_area.buffer).to eq(["Line 1", "Line 2", "Line 3"])
    end

    it "ignores nil or empty content" do
      output_area.append(nil)
      output_area.append("")
      expect(output_area.buffer).to be_empty
    end
  end

  describe "#scroll_up" do
    before do
      20.times { |i| output_area.append("Line #{i}") }
    end

    it "scrolls up to show older content" do
      initial_offset = output_area.scroll_offset
      output_area.scroll_up(5)
      expect(output_area.scroll_offset).to eq(initial_offset + 5)
    end

    it "does not scroll beyond buffer size" do
      output_area.scroll_up(100)
      max_scroll = [output_area.buffer.size - output_area.height, 0].max
      expect(output_area.scroll_offset).to eq(max_scroll)
    end
  end

  describe "#scroll_down" do
    before do
      20.times { |i| output_area.append("Line #{i}") }
      output_area.scroll_up(10)
    end

    it "scrolls down to show newer content" do
      initial_offset = output_area.scroll_offset
      output_area.scroll_down(5)
      expect(output_area.scroll_offset).to eq(initial_offset - 5)
    end

    it "does not scroll below zero" do
      output_area.scroll_down(100)
      expect(output_area.scroll_offset).to eq(0)
    end
  end

  describe "#at_bottom?" do
    it "returns true when at bottom of buffer" do
      output_area.append("Test")
      expect(output_area).to be_at_bottom
    end

    it "returns false when scrolled up" do
      20.times { |i| output_area.append("Line #{i}") }
      output_area.scroll_up(5)
      expect(output_area).not_to be_at_bottom
    end
  end

  describe "#scroll_to_top" do
    before do
      20.times { |i| output_area.append("Line #{i}") }
    end

    it "scrolls to the top of buffer" do
      output_area.scroll_to_top
      max_scroll = [output_area.buffer.size - output_area.height, 0].max
      expect(output_area.scroll_offset).to eq(max_scroll)
    end
  end

  describe "#scroll_to_bottom" do
    before do
      20.times { |i| output_area.append("Line #{i}") }
      output_area.scroll_up(10)
    end

    it "scrolls to the bottom of buffer" do
      output_area.scroll_to_bottom
      expect(output_area.scroll_offset).to eq(0)
    end
  end

  describe "#clear" do
    it "clears all content and resets scroll" do
      10.times { |i| output_area.append("Line #{i}") }
      output_area.scroll_up(5)

      output_area.clear

      expect(output_area.buffer).to be_empty
      expect(output_area.scroll_offset).to eq(0)
    end
  end

  describe "#visible_range" do
    before do
      20.times { |i| output_area.append("Line #{i}") }
    end

    it "returns correct range information" do
      range = output_area.visible_range
      expect(range[:total]).to eq(20)
      expect(range[:end] - range[:start] + 1).to be <= output_area.height
    end
  end

  describe "#scroll_percentage" do
    it "returns 0.0 when at bottom" do
      20.times { |i| output_area.append("Line #{i}") }
      expect(output_area.scroll_percentage).to eq(0.0)
    end

    it "returns 100.0 when at top" do
      20.times { |i| output_area.append("Line #{i}") }
      output_area.scroll_to_top
      expect(output_area.scroll_percentage).to eq(100.0)
    end

    it "returns 0.0 for buffer smaller than height" do
      output_area.append("Line 1")
      expect(output_area.scroll_percentage).to eq(0.0)
    end
  end
end
