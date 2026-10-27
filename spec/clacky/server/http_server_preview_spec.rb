# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

RSpec.describe Clacky::Server::HttpServer, "preview route" do
  let(:tmpdir)   { Dir.mktmpdir("clacky_preview_spec") }
  let(:sessions) { File.join(tmpdir, "sessions") }
  let(:workspace) { File.join(tmpdir, "workspace") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "test-model",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", File.join(tmpdir, "config.yml"))
    cfg
  end

  def make_server
    described_class.new(
      host:           "127.0.0.1",
      port:           0,
      agent_config:   agent_config,
      client_factory: -> { double("client") },
      sessions_dir:   sessions
    )
  end

  # Minimal request double: serve_preview only reads request_method + path.
  def req(method, path)
    double("req", request_method: method, path: path)
  end

  # Response double that also records assigned headers (fake_res swallows them).
  def res
    r    = double("res")
    head = {}
    jar  = []
    allow(r).to receive(:status=) { |v| r.instance_variable_set(:@status, v) }
    allow(r).to receive(:[]=)     { |k, v| head[k] = v }
    allow(r).to receive(:body=)   { |v| r.instance_variable_set(:@body, v) }
    allow(r).to receive(:status)  { r.instance_variable_get(:@status) }
    allow(r).to receive(:body)    { r.instance_variable_get(:@body) }
    allow(r).to receive(:headers) { head }
    allow(r).to receive(:cookies) { jar }
    r
  end

  def serve(server, method, path)
    r = res
    server.send(:serve_preview, req(method, path), r)
    r
  end

  before do
    FileUtils.mkdir_p(sessions)
    FileUtils.mkdir_p(workspace)
  end

  after { FileUtils.rm_rf(tmpdir) }

  let(:server) { make_server }
  let!(:session_id) do
    server.instance_variable_get(:@session_manager).save(
      session_id: "prevtest123456", created_at: Time.now.utc.iso8601, working_dir: workspace
    )
    "prevtest123456"
  end

  describe "GET /preview/s/<session>/<rel>" do
    it "serves an HTML file with no-store and nosniff headers" do
      File.write(File.join(workspace, "index.html"), "<h1>hello</h1>")

      r = serve(server, "GET", "/preview/s/prevtest123456/index.html")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Type"]).to eq("text/html; charset=utf-8")
      expect(r.headers["Cache-Control"]).to eq("no-store")
      expect(r.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(r.body).to include("<h1>hello</h1>")
    end

    it "injects the navigation reporter after <head> in HTML responses" do
      html = "<!DOCTYPE html><html><head><title>t</title></head><body><h1>hi</h1></body></html>"
      File.write(File.join(workspace, "index.html"), html)

      r = serve(server, "GET", "/preview/s/prevtest123456/index.html")

      expect(r.status).to eq(200)
      expect(r.body).to start_with("<!DOCTYPE html>")
      expect(r.body.index("__clackyPreview")).to be > r.body.index("<head>")
      expect(r.body.index("__clackyPreview")).to be < r.body.index("<h1>")
      expect(r.headers["Content-Length"].to_i).to eq(r.body.bytesize)
    end

    it "keeps the doctype first when the document has no head" do
      File.write(File.join(workspace, "plain.html"), "<!DOCTYPE html><p>plain</p>")

      r = serve(server, "GET", "/preview/s/prevtest123456/plain.html")

      expect(r.body).to start_with("<!DOCTYPE html>")
      expect(r.body).to include("__clackyPreview")
    end

    it "does not inject into non-HTML assets" do
      File.write(File.join(workspace, "app.css"), "body{}")

      r = serve(server, "GET", "/preview/s/prevtest123456/app.css")

      expect(r.body).to eq("body{}")
    end

    it "resolves each asset type to its MIME" do
      { "app.css" => "text/css; charset=utf-8",
        "app.js"  => "text/javascript; charset=utf-8",
        "logo.svg" => "image/svg+xml",
        "data.json" => "application/json; charset=utf-8",
        "font.woff2" => "font/woff2" }.each do |file, ctype|
        File.write(File.join(workspace, file), "x")
        r = serve(server, "GET", "/preview/s/prevtest123456/#{file}")
        expect(r.headers["Content-Type"]).to eq(ctype), file
      end
    end

    it "falls back to octet-stream for unlisted extensions" do
      File.write(File.join(workspace, "payload.exe"), "bin")

      r = serve(server, "GET", "/preview/s/prevtest123456/payload.exe")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Type"]).to eq("application/octet-stream")
    end

    it "serves index.html when the rel targets a directory" do
      FileUtils.mkdir_p(File.join(workspace, "site"))
      File.write(File.join(workspace, "site", "index.html"), "<p>site</p>")

      r = serve(server, "GET", "/preview/s/prevtest123456/site")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Type"]).to eq("text/html; charset=utf-8")
      expect(r.body).to include("<p>site</p>")
    end

    it "serves the workspace root index for an empty rel" do
      File.write(File.join(workspace, "index.html"), "root")

      r = serve(server, "GET", "/preview/s/prevtest123456/")

      expect(r.status).to eq(200)
      expect(r.body).to include("root")
    end

    it "decodes percent-encoded non-ASCII file names" do
      File.write(File.join(workspace, "页面.html"), "cn")

      r = serve(server, "GET", "/preview/s/prevtest123456/%E9%A1%B5%E9%9D%A2.html")

      expect(r.status).to eq(200)
      expect(r.body).to include("cn")
    end

    it "keeps '+' literal in file names" do
      File.write(File.join(workspace, "a+b.html"), "plus")

      r = serve(server, "GET", "/preview/s/prevtest123456/a+b.html")

      expect(r.status).to eq(200)
      expect(r.body).to include("plus")
    end
  end

  describe "failures" do
    it "404s on traversal outside the workspace" do
      File.write(File.join(tmpdir, "secret.txt"), "s")

      r = serve(server, "GET", "/preview/s/prevtest123456/../../secret.txt")

      expect(r.status).to eq(404)
    end

    it "404s on encoded traversal outside the workspace" do
      r = serve(server, "GET", "/preview/s/prevtest123456/%2e%2e/%2e%2e/etc/passwd")

      expect(r.status).to eq(404)
    end

    it "404s for an unknown session" do
      r = serve(server, "GET", "/preview/s/nosuchsession/index.html")

      expect(r.status).to eq(404)
    end

    it "404s for a missing file" do
      r = serve(server, "GET", "/preview/s/prevtest123456/nope.html")

      expect(r.status).to eq(404)
    end

    it "404s when the path is not under /preview/s/" do
      r = serve(server, "GET", "/preview/whatever")

      expect(r.status).to eq(404)
    end
  end

  describe "HEAD" do
    it "returns 200 with the file size but no body" do
      File.write(File.join(workspace, "page.html"), "12345")

      r = serve(server, "HEAD", "/preview/s/prevtest123456/page.html")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Length"]).to eq("5")
      expect(r.body).to eq("")
    end

    it "does not inject the reporter into HEAD responses" do
      File.write(File.join(workspace, "h.html"), "<p>x</p>")

      r = serve(server, "HEAD", "/preview/s/prevtest123456/h.html")

      expect(r.body).to eq("")
      expect(r.headers["Content-Length"].to_i).to eq(8)
    end
  end

  describe "other methods" do
    it "rejects POST with 405" do
      r = serve(server, "POST", "/preview/s/prevtest123456/index.html")

      expect(r.status).to eq(405)
      expect(r.headers["Allow"]).to eq("GET, HEAD")
    end
  end

  describe "proxy route /preview/p/<port>/<path>" do
    # Boots a throwaway WEBrick on 127.0.0.1 and yields its port. The proxy
    # only ever targets 127.0.0.1, so the upstream must bind the same host.
    def with_upstream(status: 200, headers: {}, body: "hello")
      upstream = WEBrick::HTTPServer.new(
        BindAddress: "127.0.0.1",
        Port: 0,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
      upstream.mount_proc("/") do |_req, res|
        res.status = status
        headers.each { |k, v| res[k] = v }
        res.body = body
      end
      thread = Thread.new { upstream.start }
      yield upstream.listeners.first.addr[1]
    ensure
      upstream.shutdown
      thread.join
    end

    # Boots a throwaway WEBrick on the IPv6 loopback and yields its port.
    # Vite 5 binds only ::1 on some macOS setups, so the proxy must fall back
    # from 127.0.0.1 to ::1 for those dev servers to be reachable at all.
    def with_ipv6_upstream
      upstream = WEBrick::HTTPServer.new(
        BindAddress: "::1",
        Port: 0,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
      upstream.mount_proc("/") do |_req, res|
        res.status = 200
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = "ipv6"
      end
      thread = Thread.new { upstream.start }
      yield upstream.listeners.first.addr[1]
    rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT, SocketError
      skip "IPv6 loopback unavailable"
    ensure
      upstream&.shutdown
      thread&.join
    end

    def serve_proxy(server, method, path, host: nil)
      r = res
      proxy_req = double("req", request_method: method, path: path, query_string: nil)
      allow(proxy_req).to receive(:[]) { |name| name == "Host" ? host : nil }
      server.send(:serve_preview_proxy, proxy_req, r)
      r
    end

    it "proxies the upstream body and strips X-Frame-Options" do
      with_upstream(
        headers: { "X-Frame-Options" => "SAMEORIGIN", "Content-Type" => "text/html; charset=utf-8" },
        body: "<h1>dev</h1>"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/index.html")

        expect(r.status).to eq(200)
        expect(r.body).to include("<h1>dev</h1>")
        expect(r.headers["Content-Type"]).to eq("text/html; charset=utf-8")
        expect(r.headers["X-Frame-Options"]).to be_nil
      end
    end

    it "strips frame-ancestors from CSP but keeps the rest" do
      with_upstream(
        headers: { "Content-Security-Policy" => "default-src 'self'; frame-ancestors 'self'; script-src 'self'" },
        body: "x"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/")

        csp = r.headers["Content-Security-Policy"]
        expect(csp).to_not include("frame-ancestors")
        expect(csp).to include("default-src 'self'")
        expect(csp).to include("script-src 'self'")
      end
    end

    it "forwards the path and query string" do
      with_upstream(body: "ok") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/foo/bar?x=1")

        expect(r.status).to eq(200)
        expect(r.body).to include("ok")
      end
    end

    it "forwards upstream cookies to the isolated preview origin" do
      with_upstream(
        headers: { "Set-Cookie" => "_clacky_app_session=abc; path=/; httponly; samesite=lax" },
        body: "ok"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/", host: "preview.localhost:7070")

        expect(r.cookies).to eq(["_clacky_app_session=abc; path=/; httponly; SameSite=None; Secure"])
      end
    end

    it "drops the Domain attribute so a cookie cannot reach the host origin" do
      with_upstream(
        headers: { "Set-Cookie" => "_clacky_app_session=abc; domain=localhost; path=/; samesite=strict; secure" },
        body: "ok"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/", host: "preview.localhost:7070")

        expect(r.cookies).to eq(["_clacky_app_session=abc; path=/; SameSite=None; Secure"])
      end
    end

    it "does not forward upstream cookies on a same-origin preview request" do
      with_upstream(
        headers: { "Set-Cookie" => "_clacky_app_session=abc; path=/" },
        body: "ok"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/", host: "127.0.0.1:7070")

        expect(r.cookies).to be_empty
      end
    end

    it "keeps a root-relative redirect inside the proxy prefix" do
      with_upstream(status: 302, headers: { "Location" => "/dashboard?tab=1" }, body: "") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/sign_in", host: "preview.localhost:7070")

        expect(r.status).to eq(302)
        expect(r.headers["Location"]).to eq("/preview/p/#{port}/dashboard?tab=1")
      end
    end

    it "folds an absolute redirect to the same dev server into the proxy prefix" do
      upstream = WEBrick::HTTPServer.new(
        BindAddress: "127.0.0.1",
        Port: 0,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
      upstream.mount_proc("/") do |_req, res|
        res.status = 302
        res["Location"] = "http://127.0.0.1:#{upstream.listeners.first.addr[1]}/home?x=1#top"
      end
      thread = Thread.new { upstream.start }
      port = upstream.listeners.first.addr[1]

      r = serve_proxy(server, "GET", "/preview/p/#{port}/sign_in", host: "preview.localhost:7070")

      expect(r.headers["Location"]).to eq("/preview/p/#{port}/home?x=1#top")
    ensure
      upstream&.shutdown
      thread&.join
    end

    it "leaves redirects to another host untouched" do
      with_upstream(status: 302, headers: { "Location" => "https://accounts.example.com/oauth" }, body: "") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/sign_in", host: "preview.localhost:7070")

        expect(r.headers["Location"]).to eq("https://accounts.example.com/oauth")
      end
    end

    it "does not rewrite redirects on a same-origin preview request" do
      with_upstream(status: 302, headers: { "Location" => "/dashboard" }, body: "") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/sign_in", host: "127.0.0.1:7070")

        expect(r.headers["Location"]).to eq("http://127.0.0.1:#{port}/dashboard")
      end
    end

    it "injects the navigation reporter into proxied HTML" do      with_upstream(
        headers: { "Content-Type" => "text/html; charset=utf-8" },
        body: "<html><head><title>x</title></head><body></body></html>"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/")

        expect(r.body).to include("__clackyPreview")
        expect(r.body).to include("turbo:load")
        expect(r.body.index("__clackyPreview")).to be < r.body.index("<title>")
      end
    end

    it "does not inject the navigation reporter into non-HTML responses" do
      with_upstream(headers: { "Content-Type" => "application/json" }, body: '{"ok":true}') do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/data.json")

        expect(r.body).to eq('{"ok":true}')
      end
    end

    it "rewrites absolute asset paths to the proxy prefix" do
      html = '<link rel="stylesheet" href="/assets/app.css">' \
             '<script src="/assets/app.js"></script>' \
             '<img src="/img/logo.png">' \
             '<a href="//cdn.example.com/x">ext</a>' \
             '<a href="http://example.com">abs</a>'
      with_upstream(headers: { "Content-Type" => "text/html; charset=utf-8" }, body: html) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/page")

        expect(r.body).to include("href=\"/preview/p/#{port}/assets/app.css\"")
        expect(r.body).to include("src=\"/preview/p/#{port}/assets/app.js\"")
        expect(r.body).to include("src=\"/preview/p/#{port}/img/logo.png\"")
        expect(r.body).to include('href="//cdn.example.com/x"')
        expect(r.body).to include('href="http://example.com"')
      end
    end

    it "rewrites absolute url() references in proxied CSS" do
      css = 'body{font-family:url("/dev-assets/inter.woff2")}' \
            '.icon{background:url(\'/img/bg.png\')}' \
            '.ext{background:url(//cdn.example.com/x.png)}'
      with_upstream(headers: { "Content-Type" => "text/css" }, body: css) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/app.css")

        expect(r.body).to include("url(\"/preview/p/#{port}/dev-assets/inter.woff2\")")
        expect(r.body).to include("url('/preview/p/#{port}/img/bg.png')")
        expect(r.body).to include("url(//cdn.example.com/x.png)")
      end
    end

    it "rejects a non-numeric port with 400" do
      expect(serve_proxy(server, "GET", "/preview/p/abc/index.html").status).to eq(400)
    end

    it "rejects out-of-range ports with 400" do
      expect(serve_proxy(server, "GET", "/preview/p/0/x").status).to eq(400)
      expect(serve_proxy(server, "GET", "/preview/p/99999/x").status).to eq(400)
    end

    it "rejects POST with 405" do
      r = serve_proxy(server, "POST", "/preview/p/3000/x")

      expect(r.status).to eq(405)
      expect(r.headers["Allow"]).to eq("GET, HEAD")
    end

    it "marks a frameable upstream so the panel can load it directly" do
      with_upstream(headers: { "Content-Type" => "text/html; charset=utf-8" }, body: "x") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/")

        expect(r.headers["X-Clacky-Upstream-Frameable"]).to eq("1")
      end
    end

    it "marks an X-Frame-Options upstream as not directly frameable" do
      with_upstream(headers: { "X-Frame-Options" => "SAMEORIGIN" }, body: "x") do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/")

        expect(r.headers["X-Clacky-Upstream-Frameable"]).to eq("0")
        expect(r.headers["X-Frame-Options"]).to be_nil
      end
    end

    it "marks a CSP frame-ancestors upstream as not directly frameable" do
      with_upstream(
        headers: { "Content-Security-Policy" => "frame-ancestors 'self'" },
        body: "x"
      ) do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/")

        expect(r.headers["X-Clacky-Upstream-Frameable"]).to eq("0")
      end
    end

    it "falls back to the IPv6 loopback when the dev server binds only ::1" do
      with_ipv6_upstream do |port|
        r = serve_proxy(server, "GET", "/preview/p/#{port}/index.html")

        expect(r.status).to eq(200)
        expect(r.body).to include("ipv6")
      end
    end

    it "returns 502 when the upstream is unreachable" do
      expect(serve_proxy(server, "GET", "/preview/p/1/").status).to eq(502)
    end
  end

  describe "local file route /preview/f/<absolute-path>" do
    let(:outside_dir) { Dir.mktmpdir("clacky_preview_outside") }

    after { FileUtils.rm_rf(outside_dir) }

    before { allow(Dir).to receive(:home).and_return(tmpdir) }

    def serve_local(server, method, path)
      r = res
      server.send(:serve_preview_local, req(method, path), r)
      r
    end

    it "serves an HTML file inside the home directory" do
      File.write(File.join(tmpdir, "report.html"), "<h1>report</h1>")

      r = serve_local(server, "GET", "/preview/f#{File.join(tmpdir, "report.html")}")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Type"]).to eq("text/html; charset=utf-8")
      expect(r.body).to include("<h1>report</h1>")
    end

    it "serves a percent-encoded non-ASCII absolute path" do
      File.write(File.join(tmpdir, "简历.html"), "cv")

      r = serve_local(server, "GET", "/preview/f#{tmpdir}/%E7%AE%80%E5%8E%86.html")

      expect(r.status).to eq(200)
      expect(r.body).to include("cv")
    end

    it "resolves a directory to its index.html" do
      FileUtils.mkdir_p(File.join(tmpdir, "site"))
      File.write(File.join(tmpdir, "site", "index.html"), "<p>site</p>")

      r = serve_local(server, "GET", "/preview/f#{File.join(tmpdir, "site")}")

      expect(r.status).to eq(200)
      expect(r.body).to include("<p>site</p>")
    end

    it "404s on a path outside the home directory" do
      outside = File.join(outside_dir, "secret.html")
      File.write(outside, "secret")

      r = serve_local(server, "GET", "/preview/f#{outside}")

      expect(r.status).to eq(404)
    end

    it "404s when the path is not absolute" do
      r = serve_local(server, "GET", "/preview/frelative/path.html")

      expect(r.status).to eq(404)
    end

    it "404s for a missing file" do
      r = serve_local(server, "GET", "/preview/f#{File.join(tmpdir, "nope.html")}")

      expect(r.status).to eq(404)
    end

    it "returns the file size and no body for HEAD" do
      File.write(File.join(tmpdir, "page.html"), "12345")

      r = serve_local(server, "HEAD", "/preview/f#{File.join(tmpdir, "page.html")}")

      expect(r.status).to eq(200)
      expect(r.headers["Content-Length"]).to eq("5")
      expect(r.body).to eq("")
    end
  end
end
