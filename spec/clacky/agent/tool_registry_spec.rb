# frozen_string_literal: true

RSpec.describe Clacky::ToolRegistry do
  let(:registry) { described_class.new }

  describe "ask_user aliasing" do
    before { registry.register(Clacky::Tools::AskUser.new) }

    it "resolves the retired request_user_feedback name to ask_user" do
      expect(registry.resolve("request_user_feedback")).to eq("ask_user")
    end

    it "resolves the shorthand aliases" do
      %w[user_feedback ask ask_question clarify].each do |name|
        expect(registry.resolve(name)).to eq("ask_user")
      end
    end

    it "prefers the exact registered name" do
      expect(registry.resolve("ask_user")).to eq("ask_user")
    end
  end
end
