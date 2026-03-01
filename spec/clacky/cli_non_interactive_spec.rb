# frozen_string_literal: true

require "spec_helper"
require "clacky/cli"
require "clacky/plain_ui_controller"

RSpec.describe "CLI --message / -i non-interactive mode" do
  let(:cli) { Clacky::CLI.new }

  # Extract the private helper so we can unit-test it directly
  let(:run_non_interactive) do
    # Expose private method for testing
    cli.class.send(:public, :run_non_interactive)
    method(:call_run_non_interactive)
  end

  def call_run_non_interactive(agent, message, images, agent_config, session_manager)
    cli.send(:run_non_interactive, agent, message, images, agent_config, session_manager)
  end

  let(:agent) { instance_double(Clacky::Agent, to_session_data: {}) }
  let(:agent_config) { Clacky::AgentConfig.new }
  let(:session_manager) { nil }

  describe "image path validation" do
    it "exits with status 1 for a missing image file" do
      allow(agent).to receive(:instance_variable_set)

      expect {
        call_run_non_interactive(agent, "hello", ["/nonexistent/image.png"], agent_config, session_manager)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "passes existing image paths to agent.run" do
      Tempfile.create(["test_image", ".png"]) do |f|
        f.write("\x89PNG") # minimal PNG header
        f.flush

        allow(agent).to receive(:instance_variable_set)
        allow(agent).to receive(:run)

        expect(agent).to receive(:run).with("describe this", images: [f.path])

        # exit(0) will raise SystemExit — catch it
        expect {
          call_run_non_interactive(agent, "describe this", [f.path], agent_config, session_manager)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    it "passes empty images array when no images given" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run)

      expect(agent).to receive(:run).with("hello", images: [])

      expect {
        call_run_non_interactive(agent, "hello", [], agent_config, session_manager)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "forces permission_mode to :auto_approve" do
      allow(agent).to receive(:instance_variable_set)
      allow(agent).to receive(:run)

      agent_config.permission_mode = :confirm_safes

      expect {
        call_run_non_interactive(agent, "hello", [], agent_config, session_manager)
      }.to raise_error(SystemExit)

      expect(agent_config.permission_mode).to eq(:auto_approve)
    end
  end
end
