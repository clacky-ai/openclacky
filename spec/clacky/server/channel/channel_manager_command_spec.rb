# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelManager do
  describe "KNOWN_COMMAND" do
    subject(:regex) { described_class::KNOWN_COMMAND }

    it "routes the slash-prefixed help aliases" do
      ["/?", "/？", "/h", "/help", "/H", "/HELP"].each do |text|
        expect(text).to match(regex)
      end
    end

    it "routes the other built-in commands" do
      ["/new", "/clear", "/model", "/model s1", "/skills", "/bind 2",
       "/unbind", "/stop", "/status", "/list"].each do |text|
        expect(text).to match(regex)
      end
    end

    # Bare "?" and "h" are everyday chat characters; they must reach the agent
    # as normal messages instead of printing the command list.
    it "leaves bare help characters to the agent" do
      ["?", "h", "help", "H", "what?", "why?", "h?", "？"].each do |text|
        expect(text).not_to match(regex)
      end
    end

    it "does not swallow longer words that merely start with a command prefix" do
      ["/hello", "/helper", "/helps", "/hmm", "/skillfoo"].each do |text|
        expect(text).not_to match(regex)
      end
    end

    # "\b" never matches after "?", so "/?" needs an explicit end anchor.
    it "requires /? to stand alone" do
      ["/?", "/？"].each { |text| expect(text).to match(regex) }
      ["/?extra", "/?x", "/？x"].each { |text| expect(text).not_to match(regex) }
    end
  end

  describe "COMMAND_HELP" do
    it "advertises the slash-prefixed help aliases" do
      expect(described_class::COMMAND_HELP).to include("/? / /h / /help")
    end

    it "no longer advertises bare help characters" do
      expect(described_class::COMMAND_HELP).not_to include("? / h / help")
    end
  end
end
