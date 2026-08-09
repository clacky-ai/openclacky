# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ApiExtensionLoader built-in extensions" do
  before { Clacky::ApiExtension.reset_registry! }

  it "loads the meeting extension from default_extensions" do
    empty_dir = Dir.mktmpdir
    begin
      allow(Clacky::ExtensionLoader).to receive(:disabled_ids).and_return(Set.new)
      allow(Clacky::ExtensionLoader).to receive(:load_all).and_wrap_original do |m, **kwargs|
        default_layers = Clacky::ExtensionLoader.default_layers
        m.call(**kwargs.merge(layers: default_layers.merge(local: empty_dir), force: true))
      end
      result = Clacky::ApiExtensionLoader.load_all
      expect(result.loaded).to include("meeting")
      expect(Clacky::ApiExtension.registry["meeting"]).not_to be_nil
    ensure
      FileUtils.remove_entry(empty_dir)
    end
  end

  it "user extension with same id overrides built-in" do
    user_dir = Dir.mktmpdir
    begin
      ext_dir = File.join(user_dir, "meeting")
      FileUtils.mkdir_p(File.join(ext_dir, "api"))
      File.write(File.join(ext_dir, "ext.yml"), <<~YAML)
        id: meeting
        name: meeting
        version: "0.0.1"
        origin: self
        contributes:
          api: api/handler.rb
      YAML
      File.write(File.join(ext_dir, "api/handler.rb"), <<~RUBY)
        class UserMeetingOverrideExt < Clacky::ApiExtension
          get "/custom" do
            json(source: "user")
          end
        end
      RUBY

      allow(Clacky::ExtensionLoader).to receive(:disabled_ids).and_return(Set.new)
      allow(Clacky::ExtensionLoader).to receive(:load_all).and_wrap_original do |m, **kwargs|
        default_layers = Clacky::ExtensionLoader.default_layers
        m.call(**kwargs.merge(layers: default_layers.merge(local: user_dir), force: true))
      end
      result = Clacky::ApiExtensionLoader.load_all
      expect(result.loaded).to include("meeting")

      klass = Clacky::ApiExtension.registry["meeting"]
      expect(klass.routes.any? { |r| r.pattern == "/custom" }).to be true
    ensure
      FileUtils.remove_entry(user_dir)
    end
  end
end

RSpec.describe "ApiExtension#submit_task" do
  before { Clacky::ApiExtension.reset_registry! }

  let(:dummy_route) do
    Clacky::ApiExtension::Route.new(
      method: :get, pattern: "/", regex: /\A\/\z/, param_names: [],
      block: proc {}, options: {}
    )
  end

  let(:registry) { double("registry") }
  let(:http_server) do
    server = double("http_server")
    allow(server).to receive(:instance_variable_get).with(:@registry).and_return(registry)
    allow(server).to receive(:instance_variable_get).with(:@session_manager).and_return(nil)
    allow(server).to receive(:instance_variable_get).with(:@agent_config).and_return(nil)
    allow(server).to receive(:instance_variable_get).with(:@start_time).and_return(Time.now)
    server
  end

  let(:instance) do
    Clacky::ApiExtension.allocate.tap do |inst|
      inst.instance_variable_set(:@req, nil)
      inst.instance_variable_set(:@res, nil)
      inst.instance_variable_set(:@route, dummy_route)
      inst.instance_variable_set(:@params, {})
      inst.instance_variable_set(:@http_server, http_server)
    end
  end

  it "submits task to an idle session" do
    allow(registry).to receive(:exist?).with("sess-1").and_return(true)
    allow(registry).to receive(:get).with("sess-1").and_return({ status: :idle })
    allow(http_server).to receive(:send).with(:run_session_task, "sess-1", "do stuff", display_message: nil)

    result = instance.submit_task("sess-1", "do stuff")
    expect(result).to eq("sess-1")
  end

  it "raises 409 if session is already running" do
    allow(registry).to receive(:exist?).with("sess-1").and_return(true)
    allow(registry).to receive(:get).with("sess-1").and_return({ status: :running })

    expect {
      instance.submit_task("sess-1", "do stuff")
    }.to raise_error(Clacky::ApiExtension::Halt) { |halt|
      expect(halt.status).to eq(409)
    }
  end

  it "raises 404 if session does not exist" do
    allow(registry).to receive(:exist?).with("sess-x").and_return(false)
    allow(registry).to receive(:ensure).with("sess-x").and_return(false)

    expect {
      instance.submit_task("sess-x", "do stuff")
    }.to raise_error(Clacky::ApiExtension::Halt) { |halt|
      expect(halt.status).to eq(404)
    }
  end
end

RSpec.describe "ApiExtension#create_session with project_id" do
  before { Clacky::ApiExtension.reset_registry! }

  let(:dummy_route) do
    Clacky::ApiExtension::Route.new(
      method: :get, pattern: "/", regex: /\A\/\z/, param_names: [],
      block: proc {}, options: {}
    )
  end

  let(:project_manager) { double("project_manager") }
  let(:registry) { double("registry") }
  let(:session_manager) { double("session_manager") }
  let(:agent) { double("agent") }
  let(:http_server) do
    server = double("http_server")
    allow(server).to receive(:instance_variable_get).with(:@registry).and_return(registry)
    allow(server).to receive(:instance_variable_get).with(:@session_manager).and_return(session_manager)
    allow(server).to receive(:instance_variable_get).with(:@project_manager).and_return(project_manager)
    server
  end

  let(:instance) do
    Clacky::ApiExtension.allocate.tap do |inst|
      inst.instance_variable_set(:@req, nil)
      inst.instance_variable_set(:@res, nil)
      inst.instance_variable_set(:@route, dummy_route)
      inst.instance_variable_set(:@params, {})
      inst.instance_variable_set(:@http_server, http_server)
    end
  end

  it "inherits the project working_dir and persists agent.project_id" do
    project = { id: "p1", name: "Proj", working_dir: "/tmp/proj" }
    allow(project_manager).to receive(:find).with("p1").and_return(project)
    allow(http_server).to receive(:send).with(:build_session, name: nil, working_dir: File.expand_path("/tmp/proj"), profile: "general", source: :manual).and_return("sess-1")
    allow(registry).to receive(:with_session).with("sess-1").and_yield({ agent: agent })
    allow(agent).to receive(:project_id=).with("p1")
    allow(agent).to receive(:to_session_data).and_return({ id: "sess-1" })
    allow(session_manager).to receive(:save)
    allow(http_server).to receive(:send).with(:broadcast_session_update, "sess-1")

    result = instance.create_session(project_id: "p1")
    expect(result).to eq("sess-1")
    expect(agent).to have_received(:project_id=).with("p1")
    expect(session_manager).to have_received(:save)
  end

  it "raises 404 when the project does not exist" do
    allow(project_manager).to receive(:find).with("nope").and_return(nil)

    expect {
      instance.create_session(project_id: "nope")
    }.to raise_error(Clacky::ApiExtension::Halt) { |halt|
      expect(halt.status).to eq(404)
    }
  end

  it "does not override an explicit working_dir with the project's" do
    project = { id: "p1", name: "Proj", working_dir: "/tmp/proj" }
    allow(project_manager).to receive(:find).with("p1").and_return(project)
    allow(http_server).to receive(:send).with(:build_session, name: nil, working_dir: "/custom/dir", profile: "general", source: :manual).and_return("sess-2")
    allow(registry).to receive(:with_session).with("sess-2").and_yield({ agent: agent })
    allow(agent).to receive(:project_id=).with("p1")
    allow(agent).to receive(:to_session_data).and_return({ id: "sess-2" })
    allow(session_manager).to receive(:save)
    allow(http_server).to receive(:send).with(:broadcast_session_update, "sess-2")

    result = instance.create_session(project_id: "p1", working_dir: "/custom/dir")
    expect(result).to eq("sess-2")
    expect(agent).to have_received(:project_id=).with("p1")
  end

  it "accepts 'ext' so extension sessions land in the folded sidebar group" do
    allow(http_server).to receive(:send).with(:build_session, name: nil, working_dir: nil, profile: "general", source: :ext).and_return("sess-3")
    allow(http_server).to receive(:send).with(:broadcast_session_update, "sess-3")

    expect(instance.create_session(source: :ext)).to eq("sess-3")
  end

  it "rejects sources outside the allowed list" do
    expect {
      instance.create_session(source: :cron)
    }.to raise_error(Clacky::ApiExtension::Halt) { |halt|
      expect(halt.status).to eq(400)
    }
  end
end
