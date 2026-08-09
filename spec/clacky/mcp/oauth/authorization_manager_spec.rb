# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "clacky/mcp/oauth/config"
require "clacky/mcp/oauth/credential_store"
require "clacky/mcp/oauth/authorization_manager"

RSpec.describe Clacky::Mcp::OAuth::AuthorizationManager do
  Response = Struct.new(:status, :headers, :body)

  let(:home) { Dir.mktmpdir }
  let(:store) { Clacky::Mcp::OAuth::CredentialStore.new(server_name: "example", home: home) }
  let(:config) do
    Clacky::Mcp::OAuth::Config.from_server_spec(
      "url" => "https://mcp.example.test/service",
      "auth" => { "type" => "oauth" }
    )
  end
  let(:now) { 1_800_000_000 }
  let(:requests) { [] }

  after { FileUtils.rm_rf(home) }

  it "performs metadata discovery, DCR, PKCE, and code exchange" do
    callback = lambda do |url, state|
      expect(url).to include("code_challenge_method=S256")
      expect(url).to include("client_id=client-123")
      { "code" => "code-456", "state" => state }
    end
    manager = build_manager(callback: callback)

    grant = manager.login

    expect(grant.fetch("access_token")).to eq("access-789")
    expect(grant.fetch("refresh_token")).to eq("refresh-789")
    expect(grant.fetch("expires_at")).to eq(now + 3600)
    registration = requests.find { |request| request[1].end_with?("/register") }
    expect(JSON.parse(registration[3])).to include(
      "application_type" => "native",
      "token_endpoint_auth_method" => "none"
    )
  end

  it "rejects an OAuth callback with a mismatched state" do
    manager = build_manager(callback: ->(_url, _state) { { "code" => "code", "state" => "wrong" } })

    expect { manager.login }.to raise_error(described_class::Error, /state mismatch/)
    expect(store.load).to be_nil
  end

  it "rejects metadata endpoints that are not HTTPS" do
    requester = lambda do |method, url, headers, body|
      if url.include?("oauth-protected-resource")
        Response.new(200, {}, JSON.generate("authorization_servers" => ["http://auth.example.test"]))
      else
        scripted_requester.call(method, url, headers, body)
      end
    end

    expect { build_manager(requester: requester).login }
      .to raise_error(described_class::Error, /HTTPS/)
  end

  it "rejects resource metadata for a different resource" do
    requester = lambda do |_method, url, _headers, _body|
      if url.include?("oauth-protected-resource")
        Response.new(200, {}, JSON.generate(
          "resource" => "https://evil.example/mcp",
          "authorization_servers" => ["https://auth.example.test"]
        ))
      else
        Response.new(404, {}, "")
      end
    end

    expect { build_manager(requester: requester).login }
      .to raise_error(described_class::Error, /does not match/)
  end

  it "rejects authorization metadata with a mismatched issuer" do
    requester = lambda do |method, url, headers, body|
      response = scripted_requester.call(method, url, headers, body)
      if url.end_with?("/.well-known/oauth-authorization-server")
        metadata = JSON.parse(response.body).merge("issuer" => "https://other.example.test")
        Response.new(200, {}, JSON.generate(metadata))
      else
        response
      end
    end

    expect { build_manager(requester: requester).login }
      .to raise_error(described_class::Error, /issuer.*match/i)
  end

  it "refreshes and rotates a refresh token" do
    manager = build_manager
    grant = {
      "client_id" => "client-123",
      "token_endpoint" => "https://auth.example.test/token",
      "refresh_token" => "old-refresh"
    }

    refreshed = manager.refresh(grant)

    expect(refreshed.fetch("access_token")).to eq("access-789")
    expect(refreshed.fetch("refresh_token")).to eq("refresh-789")
  end

  it "does not include response bodies or token values in errors" do
    requester = ->(*_args) { Response.new(400, {}, '{"access_token":"do-not-leak"}') }

    expect { build_manager(requester: requester).login }
      .to raise_error(described_class::Error) { |error| expect(error.message).not_to include("do-not-leak") }
  end

  def build_manager(requester: scripted_requester, callback: nil)
    described_class.new(
      server_name: "example",
      config: config,
      store: store,
      requester: requester,
      callback: callback || ->(_url, state) { { "code" => "code-456", "state" => state } },
      clock: -> { now }
    )
  end

  def scripted_requester
    lambda do |method, url, headers, body|
      requests << [method, url, headers, body]
      case url
      when "https://mcp.example.test/.well-known/oauth-protected-resource/service"
        Response.new(200, {}, JSON.generate(
          "resource" => "https://mcp.example.test/service",
          "authorization_servers" => ["https://auth.example.test"]
        ))
      when "https://auth.example.test/.well-known/oauth-authorization-server"
        Response.new(200, {}, JSON.generate(
          "issuer" => "https://auth.example.test",
          "authorization_endpoint" => "https://auth.example.test/authorize",
          "token_endpoint" => "https://auth.example.test/token",
          "registration_endpoint" => "https://auth.example.test/register",
          "code_challenge_methods_supported" => ["S256"]
        ))
      when "https://auth.example.test/register"
        Response.new(201, {}, JSON.generate("client_id" => "client-123"))
      when "https://auth.example.test/token"
        Response.new(200, {}, JSON.generate(
          "access_token" => "access-789",
          "refresh_token" => "refresh-789",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        ))
      else
        Response.new(404, {}, "")
      end
    end
  end
end
