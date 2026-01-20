# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/input_area"

RSpec.describe Clacky::UI2::Components::InputArea do
  let(:input_area) { described_class.new(row: 20) }

  describe "#insert_char" do
    it "inserts character at cursor position" do
      input_area.insert_char("H")
      input_area.insert_char("i")
      expect(input_area.input_buffer).to eq("Hi")
    end

    it "inserts at current cursor position" do
      input_area.insert_char("A")
      input_area.insert_char("C")
      input_area.cursor_left
      input_area.insert_char("B")
      expect(input_area.input_buffer).to eq("ABC")
    end
  end

  describe "#backspace" do
    before do
      "Hello".each_char { |c| input_area.insert_char(c) }
    end

    it "removes character before cursor" do
      input_area.backspace
      expect(input_area.input_buffer).to eq("Hell")
    end

    it "does nothing at start of buffer" do
      input_area.cursor_home
      input_area.backspace
      expect(input_area.input_buffer).to eq("Hello")
    end

    it "updates cursor position" do
      initial_pos = input_area.cursor_position
      input_area.backspace
      expect(input_area.cursor_position).to eq(initial_pos - 1)
    end
  end

  describe "#delete_char" do
    before do
      "Hello".each_char { |c| input_area.insert_char(c) }
      input_area.cursor_home
    end

    it "removes character at cursor position" do
      input_area.delete_char
      expect(input_area.input_buffer).to eq("ello")
    end

    it "does nothing at end of buffer" do
      input_area.cursor_end
      input_area.delete_char
      expect(input_area.input_buffer).to eq("Hello")
    end
  end

  describe "cursor movement" do
    before do
      "Hello".each_char { |c| input_area.insert_char(c) }
    end

    describe "#cursor_left" do
      it "moves cursor left" do
        initial_pos = input_area.cursor_position
        input_area.cursor_left
        expect(input_area.cursor_position).to eq(initial_pos - 1)
      end

      it "does not move below 0" do
        input_area.cursor_home
        input_area.cursor_left
        expect(input_area.cursor_position).to eq(0)
      end
    end

    describe "#cursor_right" do
      it "moves cursor right" do
        input_area.cursor_home
        input_area.cursor_right
        expect(input_area.cursor_position).to eq(1)
      end

      it "does not move beyond buffer length" do
        input_area.cursor_right
        expect(input_area.cursor_position).to eq(input_area.input_buffer.length)
      end
    end

    describe "#cursor_home" do
      it "moves cursor to start" do
        input_area.cursor_home
        expect(input_area.cursor_position).to eq(0)
      end
    end

    describe "#cursor_end" do
      it "moves cursor to end" do
        input_area.cursor_home
        input_area.cursor_end
        expect(input_area.cursor_position).to eq(input_area.input_buffer.length)
      end
    end
  end

  describe "#submit" do
    before do
      "Test input".each_char { |c| input_area.insert_char(c) }
    end

    it "returns current input value" do
      result = input_area.submit
      expect(result[:text]).to eq("Test input")
      expect(result[:images]).to eq([])
    end

    it "clears the buffer" do
      input_area.submit
      expect(input_area.input_buffer).to be_empty
    end

    it "resets cursor position" do
      input_area.submit
      expect(input_area.cursor_position).to eq(0)
    end

    it "adds to history" do
      input_area.submit
      input_area.history_prev
      expect(input_area.input_buffer).to eq("Test input")
    end
  end

  describe "#clear" do
    it "clears buffer and resets cursor" do
      "Test".each_char { |c| input_area.insert_char(c) }
      input_area.clear
      expect(input_area.input_buffer).to be_empty
      expect(input_area.cursor_position).to eq(0)
    end
  end

  describe "history navigation" do
    before do
      input_area.insert_char("F")
      input_area.insert_char("i")
      input_area.insert_char("r")
      input_area.insert_char("s")
      input_area.insert_char("t")
      input_area.submit

      input_area.insert_char("S")
      input_area.insert_char("e")
      input_area.insert_char("c")
      input_area.insert_char("o")
      input_area.insert_char("n")
      input_area.insert_char("d")
      input_area.submit
    end

    describe "#history_prev" do
      it "loads previous history entry" do
        input_area.history_prev
        expect(input_area.input_buffer).to eq("Second")
      end

      it "can navigate multiple entries" do
        input_area.history_prev
        input_area.history_prev
        expect(input_area.input_buffer).to eq("First")
      end

      it "stops at oldest entry" do
        3.times { input_area.history_prev }
        expect(input_area.input_buffer).to eq("First")
      end
    end

    describe "#history_next" do
      it "loads next history entry" do
        2.times { input_area.history_prev }
        input_area.history_next
        expect(input_area.input_buffer).to eq("Second")
      end

      it "clears input when reaching end" do
        input_area.history_prev
        input_area.history_next
        expect(input_area.input_buffer).to be_empty
      end
    end
  end

  describe "#current_content" do
    it "returns prompt with input" do
      "Test".each_char { |c| input_area.insert_char(c) }
      expect(input_area.current_content).to include("Test")
      expect(input_area.current_content).to include("[>>]")
    end

    it "returns empty string when buffer is empty" do
      expect(input_area.current_content).to eq("")
    end
  end

  describe "#empty?" do
    it "returns true when buffer is empty" do
      expect(input_area).to be_empty
    end

    it "returns false when buffer has content" do
      input_area.insert_char("X")
      expect(input_area).not_to be_empty
    end
  end
end
