# frozen_string_literal: true

require "spec_helper"
require File.expand_path(
  "../../../lib/clacky/default_extensions/computer-use/lib/computer/keycodes", __dir__
)

RSpec.describe Clacky::Computer::Keycodes do
  describe ".parse" do
    it "splits a plain key" do
      expect(described_class.parse("return")).to eq([[], "return"])
    end

    it "splits modifiers from a combo" do
      expect(described_class.parse("cmd+shift+t")).to eq([%w[cmd shift], "t"])
    end

    it "normalizes aliases and case" do
      expect(described_class.parse("Command+T")).to eq([["cmd"], "t"])
      expect(described_class.parse("option+esc")).to eq([["opt"], "esc"])
    end

    it "tolerates sloppy spacing" do
      expect(described_class.parse(" cmd + t ")).to eq([["cmd"], "t"])
    end
  end

  describe ".code_for" do
    it "maps known keys" do
      expect(described_class.code_for("return")).to eq(36)
      expect(described_class.code_for("enter")).to eq(36)
      expect(described_class.code_for("esc")).to eq(53)
      expect(described_class.code_for("a")).to eq(0)
      expect(described_class.code_for("space")).to eq(49)
      expect(described_class.code_for("left")).to eq(123)
      expect(described_class.code_for("f5")).to eq(96)
      expect(described_class.code_for("forward_delete")).to eq(117)
    end

    it "returns nil for unknown keys" do
      expect(described_class.code_for("nonsense")).to be_nil
      expect(described_class.code_for(nil)).to be_nil
    end
  end

  describe ".flags_for / .modifier? / .modifier_keycode" do
    it "ORs modifier flag masks" do
      expect(described_class.flags_for(%w[cmd shift]))
        .to eq((1 << 20) | (1 << 17))
      expect(described_class.flags_for([])).to eq(0)
    end

    it "treats unknown modifiers as no flags" do
      expect(described_class.flags_for(["bogus"])).to eq(0)
    end

    it "recognizes modifiers" do
      expect(described_class.modifier?("cmd")).to be true
      expect(described_class.modifier?("alt")).to be true
      expect(described_class.modifier?("return")).to be false
    end

    it "maps modifiers to their keycodes" do
      expect(described_class.modifier_keycode("cmd")).to eq(55)
      expect(described_class.modifier_keycode("shift")).to eq(56)
      expect(described_class.modifier_keycode("fn")).to eq(63)
      expect(described_class.modifier_keycode("nope")).to be_nil
    end
  end
end
