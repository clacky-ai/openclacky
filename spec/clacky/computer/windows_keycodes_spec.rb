# frozen_string_literal: true

require "spec_helper"
require File.expand_path(
  "../../../lib/clacky/default_extensions/computer-use/lib/computer/windows_keycodes", __dir__
)

RSpec.describe Clacky::Computer::WindowsKeycodes do
  describe ".parse" do
    it "splits a plain key" do
      expect(described_class.parse("enter")).to eq([[], "enter"])
    end

    it "splits modifiers from a combo" do
      expect(described_class.parse("ctrl+shift+t")).to eq([%w[ctrl shift], "t"])
    end

    it "maps the macOS modifier names onto their Windows keys" do
      expect(described_class.parse("cmd+space")).to eq([["win"], "space"])
      expect(described_class.parse("option+tab")).to eq([["alt"], "tab"])
      expect(described_class.parse("Command+T")).to eq([["win"], "t"])
    end

    it "normalizes key aliases when looking a key up" do
      expect(described_class.parse("arrow_left")).to eq([[], "arrow_left"])
      expect(described_class.parse("pageup")).to eq([[], "pageup"])
      expect(described_class.parse("return")).to eq([[], "return"])
    end

    it "tolerates sloppy spacing" do
      expect(described_class.parse(" ctrl + t ")).to eq([["ctrl"], "t"])
    end
  end

  describe ".code_for" do
    it "maps known keys" do
      expect(described_class.code_for("enter")).to eq(0x0D)
      expect(described_class.code_for("esc")).to eq(0x1B)
      expect(described_class.code_for("space")).to eq(0x20)
      expect(described_class.code_for("a")).to eq(0x41)
      expect(described_class.code_for("0")).to eq(0x30)
      expect(described_class.code_for("f5")).to eq(0x74)
      expect(described_class.code_for("left")).to eq(0x25)
      expect(described_class.code_for("delete")).to eq(0x2E)
    end

    it "maps the punctuation keys that share an OEM code" do
      expect(described_class.code_for("semicolon")).to eq(0xBA)
      expect(described_class.code_for(";")).to eq(0xBA)
      expect(described_class.code_for("slash")).to eq(0xBF)
      expect(described_class.code_for("/")).to eq(0xBF)
    end

    it "maps aliases onto the same code as their canonical name" do
      expect(described_class.code_for("return")).to eq(0x0D)
      expect(described_class.code_for("pageup")).to eq(0x21)
      expect(described_class.code_for("arrow_left")).to eq(0x25)
      expect(described_class.code_for("Command")).to eq(0x5B)
      expect(described_class.code_for("shift")).to eq(0x10)
      expect(described_class.code_for("ctrl")).to eq(0x11)
    end

    it "returns nil for unknown keys" do
      expect(described_class.code_for("nonsense")).to be_nil
      expect(described_class.code_for(nil)).to be_nil
    end
  end

  describe ".modifier_vks" do
    # Windows presses modifiers individually, so order is load-bearing: the
    # shortcut only registers when they go down before the main key.
    it "returns virtual keys in press order regardless of input order" do
      expect(described_class.modifier_vks(%w[shift ctrl])).to eq([0x11, 0x10])
      expect(described_class.modifier_vks(%w[alt ctrl shift])).to eq([0x11, 0x10, 0x12])
    end

    it "deduplicates and drops unknown modifiers" do
      expect(described_class.modifier_vks(%w[ctrl ctrl bogus])).to eq([0x11])
      expect(described_class.modifier_vks([])).to eq([])
    end

    it "maps cmd to the Windows key" do
      expect(described_class.modifier_vks(["cmd"])).to eq([0x5B])
    end
  end

  describe ".modifier?" do
    it "recognizes modifiers" do
      expect(described_class.modifier?("ctrl")).to be true
      expect(described_class.modifier?("cmd")).to be true
      expect(described_class.modifier?("return")).to be false
    end
  end
end
