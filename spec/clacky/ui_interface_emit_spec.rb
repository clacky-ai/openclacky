# frozen_string_literal: true

require "spec_helper"
require "clacky/server/web_ui_controller"

RSpec.describe "UIInterface#emit" do
  describe "the default implementation" do
    let(:bare_ui) do
      Class.new { include Clacky::UIInterface }.new
    end

    it "is available on every UI controller" do
      expect(bare_ui).to respond_to(:emit)
    end

    it "silently drops the event instead of raising" do
      expect { bare_ui.emit("ext.demo.tick", step: 1) }.not_to raise_error
    end

    it "is inherited by UIs with no event channel" do
      expect(Clacky::NullUIController.new).to respond_to(:emit)
      expect { Clacky::NullUIController.new.emit("ext.demo.tick", step: 1) }.not_to raise_error
    end
  end

  describe "JsonUIController" do
    let(:output) { StringIO.new }
    let(:ui) { Clacky::JsonUIController.new(output:) }

    it "writes the custom event as NDJSON" do
      ui.emit("ext.demo.progress", done: 2, total: 6)

      event = JSON.parse(output.string.lines.last)
      expect(event["type"]).to eq("ext.demo.progress")
      expect(event["done"]).to eq(2)
      expect(event["total"]).to eq(6)
    end
  end

  describe "WebUIController" do
    let(:events) { [] }
    let(:ui) do
      Clacky::Server::WebUIController.new("sess-1", ->(_sid, event) { events << event })
    end

    it "broadcasts the custom event with the session id attached" do
      ui.emit("ext.demo.progress", done: 2, total: 6)

      expect(events.last).to include(type: "ext.demo.progress", session_id: "sess-1", done: 2, total: 6)
    end

    it "tags the event with the surrounding phase so the UI can group it" do
      ui.with_phase(kind: "subagent") do |pid|
        ui.emit("ext.demo.tick", step: 1)
        expect(events.last[:phase_id]).to eq(pid)
      end
    end

    it "lets an explicit phase_id win over the ambient one" do
      ui.with_phase(kind: "subagent") do
        ui.emit("ext.demo.tick", step: 1, phase_id: "explicit")
      end

      expect(events.find { |e| e[:type] == "ext.demo.tick" }[:phase_id]).to eq("explicit")
    end
  end
end
