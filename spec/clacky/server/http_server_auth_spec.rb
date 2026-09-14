require "spec_helper"
require "clacky/server/http_server"

# ---------------------------------------------------------------------------
# Unit tests for HttpServer access key authentication logic.
#
# These tests exercise the brute-force protection state machine directly,
# without booting a real HTTP server. The failures hash and mutex mirror
# the instance variables initialised in HttpServer#initialize.
# ---------------------------------------------------------------------------

RSpec.describe "HttpServer access key authentication" do
  # ── Shared state (mirrors HttpServer internals) ──────────────────────────
  let(:mutex)    { Mutex.new }
  let(:failures) { {} }
  let(:ip)       { "1.2.3.4" }

  # Simulate n consecutive wrong-key attempts from ip.
  def simulate_failures(n, reset_in: 300)
    mutex.synchronize do
      entry = failures[ip] ||= { count: 0, reset_at: Time.now + reset_in }
      n.times { entry[:count] += 1 }
    end
  end

  # Returns true when the IP is currently locked out.
  def locked_out?
    entry = failures[ip]
    entry && entry[:count] >= 10 && Time.now < entry[:reset_at]
  end

  # ── local_host? behaviour ─────────────────────────────────────────────────
  describe "local_host?" do
    def local_host?(host)
      ["127.0.0.1", "::1", "localhost"].include?(host.to_s.strip)
    end

    it "treats 127.0.0.1 as localhost" do
      expect(local_host?("127.0.0.1")).to be true
    end

    it "treats ::1 as localhost" do
      expect(local_host?("::1")).to be true
    end

    it "treats 0.0.0.0 as public" do
      expect(local_host?("0.0.0.0")).to be false
    end

    it "treats arbitrary IPs as public" do
      expect(local_host?("192.168.1.1")).to be false
    end
  end

  # ── resolve_access_key behaviour ─────────────────────────────────────────
  describe "resolve_access_key" do
    it "returns key from CLACKY_ACCESS_KEY env var" do
      with_env("CLACKY_ACCESS_KEY" => "env-secret") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to eq("env-secret")
      end
    end

    it "returns nil when env var is blank" do
      with_env("CLACKY_ACCESS_KEY" => "   ") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to be_nil
      end
    end

    it "returns nil when env var is not set" do
      with_env("CLACKY_ACCESS_KEY" => "") do
        key = ENV.fetch("CLACKY_ACCESS_KEY", "").strip
        key = key.empty? ? nil : key
        expect(key).to be_nil
      end
    end
  end

  # ── Lockout threshold ─────────────────────────────────────────────────────
  describe "lockout threshold" do
    it "does not lock out after 9 failures" do
      simulate_failures(9)
      expect(failures[ip][:count]).to eq(9)
      expect(locked_out?).to be false
    end

    it "locks out at exactly 10 failures" do
      simulate_failures(10)
      expect(locked_out?).to be true
    end
  end

  # ── Lockout duration ──────────────────────────────────────────────────────
  describe "lockout duration" do
    it "sets reset_at to ~300s in the future" do
      simulate_failures(10)
      expect(failures[ip][:reset_at]).to be_within(5).of(Time.now + 300)
    end

    it "remains locked during the lockout window" do
      simulate_failures(10, reset_in: 300)
      expect(locked_out?).to be true
    end

    it "unlocks after reset_at has passed" do
      simulate_failures(10, reset_in: -1)
      expect(locked_out?).to be false
    end
  end

  # ── Missing key must not increment failure counter ────────────────────────
  describe "missing key does not count as failure" do
    it "failure count stays 0 when no key is provided" do
      # Simulate the nil-candidate branch: failures hash must remain untouched.
      candidate = nil
      unless candidate.nil? || candidate.to_s.empty?
        mutex.synchronize do
          entry = failures[ip] ||= { count: 0, reset_at: Time.now + 300 }
          entry[:count] += 1
        end
      end
      expect(failures[ip]).to be_nil
    end
  end

  # ── Successful auth clears the failure record ─────────────────────────────
  describe "successful auth clears record" do
    it "removes the IP entry on successful login" do
      simulate_failures(5)
      expect(failures[ip]).not_to be_nil
      mutex.synchronize { failures.delete(ip) }
      expect(failures[ip]).to be_nil
    end
  end

  # ── extract_key: cookie fallback ─────────────────────────────────────────
  # REGRESSION GUARD: The cookie branch was accidentally removed in a prior
  # refactor. This block ensures it is never silently deleted again.
  describe "extract_key cookie fallback" do

    # allocate bypasses initialize entirely, giving us a bare instance.
    # extract_key is a pure function: it only reads from req and touches
    # no instance variables, so no setup is needed.
    let(:server) { Clacky::Server::HttpServer.allocate }

    def make_req(authorization: nil, query_string: "", cookies: {})
      req = double("WEBrick::HTTPRequest")
      allow(req).to receive(:[]) { |k| k == "Authorization" ? authorization.to_s : "" }
      allow(req).to receive(:query_string).and_return(query_string)
      allow(req).to receive(:cookies).and_return(
        cookies.map { |name, value| double("cookie", name: name.to_s, value: value.to_s) }
      )
      req
    end

    it "returns the cookie value when no header or query param is present" do
      req = make_req(cookies: { "clacky_access_key" => "cookie-secret" })
      expect(server.send(:extract_key, req)).to eq("cookie-secret")
    end

    it "ignores cookies with unrelated names" do
      req = make_req(cookies: { "other_cookie" => "irrelevant" })
      expect(server.send(:extract_key, req)).to be_nil
    end

    it "returns nil when cookie value is empty" do
      req = make_req(cookies: { "clacky_access_key" => "" })
      expect(server.send(:extract_key, req)).to be_nil
    end

    it "prefers Bearer header over cookie" do
      req = make_req(
        authorization: "Bearer header-wins",
        cookies:       { "clacky_access_key" => "cookie-key" }
      )
      expect(server.send(:extract_key, req)).to eq("header-wins")
    end

    it "prefers query param over cookie" do
      req = make_req(
        query_string: "access_key=query-wins",
        cookies:      { "clacky_access_key" => "cookie-key" }
      )
      expect(server.send(:extract_key, req)).to eq("query-wins")
    end

    it "falls back to cookie when header and query param are absent" do
      req = make_req(cookies: { "clacky_access_key" => "cookie-wins" })
      expect(server.send(:extract_key, req)).to eq("cookie-wins")
    end

    it "returns nil when all sources are empty" do
      expect(server.send(:extract_key, make_req)).to be_nil
    end
  end

  # ── loopback_ip? helper ──────────────────────────────────────────────────
  describe "loopback_ip?" do
    let(:server) { Clacky::Server::HttpServer.allocate }

    it "treats 127.0.0.1 as loopback" do
      expect(server.send(:loopback_ip?, "127.0.0.1")).to be true
    end

    it "treats ::1 as loopback" do
      expect(server.send(:loopback_ip?, "::1")).to be true
    end

    it "treats 127.x.y.z as loopback" do
      expect(server.send(:loopback_ip?, "127.0.0.5")).to be true
    end

    it "treats IPv4-mapped loopback as loopback" do
      expect(server.send(:loopback_ip?, "::ffff:127.0.0.1")).to be true
    end

    it "rejects LAN addresses" do
      expect(server.send(:loopback_ip?, "192.168.1.10")).to be false
    end

    it "rejects nil" do
      expect(server.send(:loopback_ip?, nil)).to be false
    end
  end

  # ── Loopback requests bypass auth in public mode ─────────────────────────
  # When the server is bound to a public address (e.g. 192.168.x.x) but the
  # request actually arrives on the loopback interface (local skills using
  # 127.0.0.1), check_access_key must short-circuit to true so child processes
  # don't need an access key.
  describe "check_access_key loopback bypass" do
    let(:server) { Clacky::Server::HttpServer.allocate }

    before do
      server.instance_variable_set(:@localhost_only, false)
      server.instance_variable_set(:@access_key, "secret")
      server.instance_variable_set(:@auth_failures, {})
      server.instance_variable_set(:@auth_failures_mutex, Mutex.new)
    end

    def make_req(peer_ip)
      req = double("WEBrick::HTTPRequest")
      allow(req).to receive(:peeraddr).and_return(["AF_INET", 0, "host", peer_ip])
      allow(req).to receive(:[]).and_return("")
      allow(req).to receive(:query_string).and_return("")
      allow(req).to receive(:cookies).and_return([])
      allow(req).to receive(:path).and_return("/api/test")
      allow(req).to receive(:request_method).and_return("GET")
      req
    end

    it "allows loopback peer without a key" do
      res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      expect(server.send(:check_access_key, make_req("127.0.0.1"), res)).to be true
    end

    it "still requires a key for non-loopback peers" do
      res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      expect(server.send(:check_access_key, make_req("192.168.1.50"), res)).to be false
      expect(res.status).to eq(401)
    end
  end

  describe "sensitive extension same-origin checks" do
    let(:server) { Clacky::Server::HttpServer.allocate }

    before do
      server.instance_variable_set(:@localhost_only, true)
      server.instance_variable_set(:@access_key, nil)
    end

    def origin_req(origin:, host:, authorization: nil, query_string: "", fetch_site: nil)
      headers = {
        "Origin" => origin,
        "Host" => host,
        "Authorization" => authorization,
        "Sec-Fetch-Site" => fetch_site
      }
      req = double("WEBrick::HTTPRequest")
      allow(req).to receive(:[]) { |key| headers[key].to_s }
      allow(req).to receive(:query_string).and_return(query_string)
      allow(req).to receive(:cookies).and_return([])
      req
    end

    it "accepts the local UI origin and non-browser local callers" do
      local = origin_req(origin: "http://127.0.0.1:7070", host: "127.0.0.1:7070")
      no_origin = origin_req(origin: "", host: "127.0.0.1:7070")

      expect(server.send(:trusted_same_origin_request?, local)).to be(true)
      expect(server.send(:trusted_same_origin_request?, no_origin)).to be(true)
    end

    it "rejects cross-origin and DNS-rebinding browser requests" do
      cross_origin = origin_req(origin: "https://evil.example", host: "127.0.0.1:7070")
      rebound = origin_req(origin: "http://evil.example:7070", host: "evil.example:7070")
      originless_cross_site = origin_req(
        origin: "", host: "127.0.0.1:7070", fetch_site: "cross-site"
      )

      expect(server.send(:trusted_same_origin_request?, cross_origin)).to be(false)
      expect(server.send(:trusted_same_origin_request?, rebound)).to be(false)
      expect(server.send(:trusted_same_origin_request?, originless_cross_site)).to be(false)
    end

    it "requires the configured access key for a non-loopback public origin" do
      server.instance_variable_set(:@localhost_only, false)
      server.instance_variable_set(:@access_key, "secret")
      missing = origin_req(origin: "https://clacky.example", host: "clacky.example")
      valid = origin_req(
        origin: "https://clacky.example",
        host: "clacky.example",
        authorization: "Bearer secret"
      )

      expect(server.send(:trusted_same_origin_request?, missing)).to be(false)
      expect(server.send(:trusted_same_origin_request?, valid)).to be(true)
    end

    it "accepts an explicitly authenticated cross-origin public client" do
      server.instance_variable_set(:@localhost_only, false)
      server.instance_variable_set(:@access_key, "secret")
      request = origin_req(
        origin: "https://integration.example",
        host: "clacky.example",
        authorization: "Bearer secret"
      )

      expect(server.send(:trusted_same_origin_request?, request)).to be(true)
    end
  end
end
