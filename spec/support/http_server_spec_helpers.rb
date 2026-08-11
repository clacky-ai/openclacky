# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

module HttpServerSpecHelpers
  # Start the server in a background thread; yield a Net::HTTP instance.
  # The server is shut down after the block returns.
  def with_server(agent_config:, client_factory: -> { double("client") }, sessions_dir: nil, projects_file: nil)
    dir = sessions_dir || Dir.mktmpdir("clacky_http_spec_sessions")
    projects_dir = Dir.mktmpdir("clacky_http_spec_projects") unless projects_file
    server = Clacky::Server::HttpServer.new(
      host:           "127.0.0.1",
      port:           0,  # OS picks a free port
      agent_config:   agent_config,
      client_factory: client_factory,
      sessions_dir:   dir,
      projects_file:  projects_file || File.join(projects_dir, "projects.json")
    )

    # We only need the dispatcher (dispatch method), not the full WEBrick loop.
    # Expose the internal dispatcher directly for unit testing via a lightweight
    # Rack-like test harness.
    yield server
  ensure
    FileUtils.rm_rf(dir) unless sessions_dir  # only clean up if we created it
    FileUtils.rm_rf(projects_dir) if projects_dir
  end

  # Build a minimal fake WEBrick request object.
  def fake_req(method:, path:, body: nil, headers: {}, query_string: "")
    req = double("req",
      request_method: method,
      path:           path,
      body:           body ? body.to_json : nil,
      query_string:   query_string,
      "[]":           nil
    )
    allow(req).to receive(:instance_variable_get).and_return(nil)
    allow(req).to receive(:[]) { |k| headers[k] }
    req
  end

  # Build a response collector that captures status + body.
  def fake_res
    res = double("res").as_null_object
    allow(res).to receive(:status=)  { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)    { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:content_type=)
    allow(res).to receive(:[]=)
    allow(res).to receive(:status)   { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)     { res.instance_variable_get(:@body) }
    res
  end

  def parsed_body(res)
    JSON.parse(res.body)
  end

  # Call the private dispatch method directly.
  def dispatch(server, req, res)
    server.send(:dispatch, req, res)
  end
end
