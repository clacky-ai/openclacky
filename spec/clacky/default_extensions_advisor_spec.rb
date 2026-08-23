# frozen_string_literal: true

require "spec_helper"
require File.expand_path("../../lib/clacky/default_extensions/advisor/hooks/advisor.rb", __dir__)

RSpec.describe "Advisor default extension" do
  let(:ext_root) { File.expand_path("../../lib/clacky/default_extensions", __dir__) }
  let(:tmp) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp) if Dir.exist?(tmp) }

  describe "manifest" do
    it "loads the advisor container with agents, hooks, panels and no errors" do
      result = Clacky::ExtensionLoader.load_all(
        layers: { builtin: ext_root, installed: tmp, local: tmp }, force: true
      )

      expect(result.errors).to be_empty
      expect(result.containers["advisor"]).not_to be_nil

      agent = result.agents.find { |a| a.ext_id == "advisor" }
      expect(agent).not_to be_nil
      expect(agent.spec["hidden"]).to be true
      expect(agent.spec["prompt_abs"]).to end_with("advisors/general.md")
      expect(File.file?(agent.spec["prompt_abs"])).to be true

      hooks = result.hooks.select { |h| h.ext_id == "advisor" }
      expect(hooks.map { |h| h.spec["event"] }).to contain_exactly("after_tool_use", "on_complete")
      hooks.each { |h| expect(File.file?(h.spec["file_abs"])).to be true }

      panel = result.panels.find { |p| p.ext_id == "advisor" }
      expect(panel).not_to be_nil
      expect(panel.spec["attach"]).to eq(["*"])
      expect(panel.spec["view"]).to eq("panels/advisor/view.js")

      api = result.api.find { |u| u.ext_id == "advisor" }
      expect(api).not_to be_nil
      expect(File.file?(api.spec["handler_abs"])).to be true
    end
  end

  describe "hook registration" do
    before { Clacky::ExtensionHookRegistry.clear! }
    after { Clacky::ExtensionHookRegistry.clear! }

    it "registers one callback per declared event" do
      Clacky::ExtensionHookRegistry.current_event = :after_tool_use
      load File.expand_path("../../lib/clacky/default_extensions/advisor/hooks/advisor_tool_use.rb", __dir__)
      Clacky::ExtensionHookRegistry.current_event = :on_complete
      load File.expand_path("../../lib/clacky/default_extensions/advisor/hooks/advisor_complete.rb", __dir__)
      Clacky::ExtensionHookRegistry.current_event = nil

      expect(Clacky::ExtensionHookRegistry.callbacks[:after_tool_use].size).to eq(1)
      expect(Clacky::ExtensionHookRegistry.callbacks[:on_complete].size).to eq(1)
    end
  end

  describe Clacky::Advisor do
    describe ".enabled_for?" do
      it "returns false for subagents" do
        agent = double("subagent")
        allow(agent).to receive(:instance_variable_get).with(:@is_subagent).and_return(true)
        allow(agent).to receive(:config).and_return(double("config"))
        expect(described_class.enabled_for?(agent)).to be false
      end

      it "returns false for a normal agent with default config" do
        agent = double("agent")
        allow(agent).to receive(:instance_variable_get).with(:@is_subagent).and_return(false)
        allow(agent).to receive(:config).and_return(double("config"))
        expect(described_class.enabled_for?(agent)).to be false
      end
    end
  end

  describe Clacky::Advisor::Worker do
    let(:advice) { "- [Run bundle exec rspec and fix any failures] Verify the changes\n- [Commit the changes] Wrap up" }
    let(:client) { double("client", send_messages: advice) }
    let(:config) { double("config", lite_model_config_for_current: nil, model_name: "test-model") }
    let(:history) { double("history", to_a: [{ role: "user", content: "Fix the build" }]) }
    let(:agent) do
      a = double("agent", session_id: "s1", config: config, history: history, working_dir: "/tmp/proj")
      allow(a).to receive(:instance_variable_get).with(:@client).and_return(client)
      allow(a).to receive(:instance_variable_get).with(:@is_subagent).and_return(false)
      allow(a).to receive(:instance_variable_get).with(:@advisor_worker).and_return(nil)
      allow(a).to receive(:instance_variable_set).with(:@advisor_worker, anything)
      allow(a).to receive(:emit_event).and_return(nil)
      a
    end
    let(:worker) { described_class.new(agent) }

    def observe_tool(name, content = "ok")
      worker.observe_tool({ name: name, id: "t1", arguments: {} }, { id: "t1", content: content })
    end

    before do
      # Run analyses synchronously in tests (real ThreadRegistry threads would
      # race the assertions).
      allow(Clacky::ThreadRegistry).to receive(:spawn) { |**kw, &block| block.call }
    end

    it "does not analyse on tool calls alone — only when the round ends" do
      observe_tool("write", "wrote lib/a.rb")
      observe_tool("grep")
      expect(Clacky::ThreadRegistry).not_to have_received(:spawn)

      worker.finish_run
      expect(Clacky::ThreadRegistry).to have_received(:spawn).once
    end

    it "recommends after a round with no tool calls at all (the first 'hi')" do
      events = []
      allow(agent).to receive(:emit_event) { |type, **data| events << [type, data] }

      worker.finish_run

      expect(Clacky::ThreadRegistry).to have_received(:spawn).once
      expect(events.map(&:first)).to eq(["ext.advisor.pending", "ext.advisor.recommendations"])
      expect(events[1][1][:content]).to eq(advice)
    end

    it "emits a pending event before the async analysis starts" do
      events = []
      allow(agent).to receive(:emit_event) { |type, **data| events << [type, data] }
      allow(client).to receive(:send_messages).and_raise("boom") # analysis fails after pending

      worker.finish_run

      expect(events.map(&:first)).to eq(["ext.advisor.pending", "ext.advisor.done"])
    end

    it "emits the advice once per completed round" do
      events = []
      allow(agent).to receive(:emit_event).with("ext.advisor.recommendations", content: advice) { |_, content:| events << content }

      observe_tool("write", "wrote lib/a.rb")
      observe_tool("grep")
      worker.finish_run
      worker.finish_run

      expect(events.size).to eq(2)
    end

    it "uses the lite model for the analysis call" do
      allow(config).to receive(:lite_model_config_for_current).and_return({ "model" => "lite-model" })

      expect(client).to receive(:send_messages).with(
        [hash_including(role: "system"), hash_including(role: "user")],
        model: "lite-model",
        max_tokens: Clacky::Advisor::DEFAULTS["max_tokens"],
        reasoning_effort: "low"
      ).and_return(advice)

      worker.finish_run
    end

    it "prefers an explicitly configured model over the lite model" do
      allow(Clacky::Advisor).to receive(:user_config).and_return({ "model" => "fast-model" })
      allow(config).to receive(:lite_model_config_for_current).and_return({ "model" => "lite-model" })
      allow(config).to receive(:find_model_by_name_and_url).with("fast-model").and_return(nil)

      expect(client).to receive(:send_messages).with(
        anything, model: "fast-model", max_tokens: anything, reasoning_effort: "low"
      ).and_return(advice)

      worker.finish_run
    end

    it "builds a dedicated client when advisor.yml names a configured model" do
      allow(Clacky::Advisor).to receive(:user_config).and_return({ "model" => "flash-model" })
      entry = {
        "api_key" => "k", "base_url" => "https://example.com/v1",
        "model" => "flash-model", "anthropic_format" => false
      }
      allow(config).to receive(:find_model_by_name_and_url).with("flash-model").and_return(entry)

      captured = nil
      allow_any_instance_of(Clacky::Client).to receive(:send_messages) do |_client, _messages, **opts|
        captured = opts[:model]
        advice
      end

      worker.finish_run

      expect(captured).to eq("flash-model")
    end

    it "includes the recent conversation in the brief" do
      allow(history).to receive(:to_a).and_return([
        { role: "user", content: "hi" },
        { role: "assistant", content: "Hello! What can I help you with?" }
      ])
      calls = []
      allow(client).to receive(:send_messages) do |messages, **|
        calls << messages[1][:content]
        advice
      end

      worker.finish_run

      expect(calls[0]).to include("- user: hi")
      expect(calls[0]).to include("- assistant: Hello! What can I help you with?")
    end

    describe "user profile context" do
      before { stub_const("Clacky::Advisor::AGENTS_DIR", File.join(tmp, "agents")) }

      it "appends USER.md and SOUL.md to the system prompt when present" do
        FileUtils.mkdir_p(File.join(tmp, "agents"))
        File.write(File.join(tmp, "agents", "USER.md"), "Reply in Chinese only.\nShort answers.")
        File.write(File.join(tmp, "agents", "SOUL.md"), "You are calm and precise.")

        calls = []
        allow(client).to receive(:send_messages) do |messages, **|
          calls << messages[0][:content]
          advice
        end

        worker.finish_run

        expect(calls[0]).to include("[USER PROFILE]")
        expect(calls[0]).to include("Reply in Chinese only.")
        expect(calls[0]).to include("[AGENT SOUL]")
        expect(calls[0]).to include("You are calm and precise.")
      end

      it "skips profile context when the agent files are absent or empty" do
        FileUtils.mkdir_p(File.join(tmp, "agents"))
        File.write(File.join(tmp, "agents", "SOUL.md"), "")

        calls = []
        allow(client).to receive(:send_messages) do |messages, **|
          calls << messages[0][:content]
          advice
        end

        worker.finish_run

        expect(calls[0]).not_to include("[USER PROFILE]")
        expect(calls[0]).not_to include("[AGENT SOUL]")
      end

      it "truncates oversized profile files" do
        FileUtils.mkdir_p(File.join(tmp, "agents"))
        File.write(File.join(tmp, "agents", "USER.md"), "x" * 5000)

        calls = []
        allow(client).to receive(:send_messages) do |messages, **|
          calls << messages[0][:content]
          advice
        end

        worker.finish_run

        expect(calls[0]).to include("[USER PROFILE]")
        expect(calls[0]).to include("x" * Clacky::Advisor::PROFILE_CHARS)
        expect(calls[0]).not_to include("x" * (Clacky::Advisor::PROFILE_CHARS + 1))
      end
    end

    it "keeps each round's trail isolated in the brief" do
      calls = []
      allow(client).to receive(:send_messages) do |messages, **|
        calls << messages[1][:content]
        advice
      end

      observe_tool("write", "wrote lib/a.rb")
      worker.finish_run

      observe_tool("read", "read lib/b.rb")
      worker.finish_run

      expect(calls.size).to eq(2)
      expect(calls[0]).to include("wrote lib/a.rb")
      expect(calls[0]).not_to include("read lib/b.rb")
      expect(calls[1]).to include("read lib/b.rb")
      expect(calls[1]).not_to include("wrote lib/a.rb")
    end

    it "emits done instead of advice when the model returns 'none'" do
      allow(client).to receive(:send_messages).and_return("none")
      events = []
      allow(agent).to receive(:emit_event) { |type, **data| events << [type, data] }

      worker.finish_run

      expect(events.map(&:first)).to eq(["ext.advisor.pending", "ext.advisor.done"])
      expect(events[1][1]).to eq(reason: "empty")
    end

    it "emits done with the error reason when analysis raises" do
      allow(client).to receive(:send_messages).and_raise("api down")
      events = []
      allow(agent).to receive(:emit_event) { |type, **data| events << [type, data] }

      worker.finish_run

      expect(events.map(&:first)).to eq(["ext.advisor.pending", "ext.advisor.done"])
      expect(events[1][1][:reason]).to eq("error")
      expect(events[1][1][:message]).to include("api down")
    end
  end

  describe "config persistence" do
    let(:config_path) { File.join(tmp, "advisor.yml") }

    before do
      stub_const("Clacky::Advisor::USER_CONFIG_PATH", config_path)
      Clacky::Advisor.reset_user_config!
    end

    after { Clacky::Advisor.reset_user_config! }

    it "is disabled by default" do
      expect(Clacky::Advisor.enabled?).to be false
    end

    it "persists disabled and re-enables" do
      Clacky::Advisor.set_enabled(false)
      expect(Clacky::Advisor.enabled?).to be false
      expect(File.file?(config_path)).to be true

      Clacky::Advisor.set_enabled(true)
      expect(Clacky::Advisor.enabled?).to be true
    end

    it "keeps existing user keys when persisting the enabled flag" do
      File.write(config_path, "model: fast-model\nmax_tokens: 4000\n")
      Clacky::Advisor.set_enabled(false)

      reloaded = YAMLCompat.safe_load(File.read(config_path))
      expect(reloaded["model"]).to eq("fast-model")
      expect(reloaded["max_tokens"]).to eq(4000)
      expect(reloaded["enabled"]).to be false
    end
  end

  describe "AdvisorExt API handler" do
    before do
      Clacky::ApiExtension.reset_registry!
      # The handler declares a fixed class name; clear its routes between
      # loads so re-loading does not accumulate duplicates.
      Clacky::AdvisorExt.reset_routes! if defined?(Clacky::AdvisorExt)
      allow(Clacky::ExtensionLoader).to receive(:load_all).and_wrap_original do |m, **kwargs|
        m.call(**kwargs.merge(layers: { builtin: ext_root, installed: tmp, local: tmp }, force: true))
      end
      Clacky::ApiExtensionLoader.load_all
    end

    after { Clacky::ApiExtension.reset_registry! }

    let(:config_path) { File.join(tmp, "advisor.yml") }
    let(:klass) { Clacky::ApiExtension.registry["advisor"] }

    def invoke_route(route)
      inst = klass.allocate
      inst.instance_variable_set(:@req, nil)
      inst.instance_variable_set(:@res, nil)
      inst.instance_variable_set(:@route, route)
      inst.instance_variable_set(:@params, {})
      inst.instance_variable_set(:@http_server, nil)
      inst.invoke
    end

    it "registers status/disable/enable routes" do
      expect(klass).not_to be_nil
      expect(klass.routes.map { |r| [r.method, r.pattern] })
        .to contain_exactly([:get, "/status"], [:post, "/disable"], [:post, "/enable"])
    end

    it "GET /status reports the current enabled state" do
      stub_const("Clacky::Advisor::USER_CONFIG_PATH", config_path)
      Clacky::Advisor.reset_user_config!

      route = klass.routes.find { |r| r.method == :get && r.pattern == "/status" }
      expect { invoke_route(route) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(JSON.parse(halt.payload)).to eq("enabled" => false)
      end

      Clacky::Advisor.set_enabled(true)
      expect { invoke_route(route) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(JSON.parse(halt.payload)).to eq("enabled" => true)
      end
    end

    it "POST /disable persists enabled=false and POST /enable restores it" do
      stub_const("Clacky::Advisor::USER_CONFIG_PATH", config_path)
      Clacky::Advisor.reset_user_config!

      disable = klass.routes.find { |r| r.method == :post && r.pattern == "/disable" }
      expect { invoke_route(disable) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(JSON.parse(halt.payload)).to eq("enabled" => false)
      end
      expect(Clacky::Advisor.enabled?).to be false

      enable = klass.routes.find { |r| r.method == :post && r.pattern == "/enable" }
      expect { invoke_route(enable) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(JSON.parse(halt.payload)).to eq("enabled" => true)
      end
      expect(Clacky::Advisor.enabled?).to be true
    end
  end

  describe Clacky::PlainUIController do
    it "prints advisor recommendations and ignores other extension events" do
      out = StringIO.new
      ui = described_class.new(output: out)

      ui.emit("ext.advisor.recommendations", content: "- [Run tests] Verify")
      ui.emit("ext.something.else", content: "should be ignored")

      expect(out.string).to include("💡")
      expect(out.string).to include("- [Run tests] Verify")
      expect(out.string).not_to include("should be ignored")
    end
  end
end
