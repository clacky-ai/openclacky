# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "clacky/mcp/oauth/credential_store"

RSpec.describe Clacky::Mcp::OAuth::CredentialStore do
  let(:home) { Dir.mktmpdir }
  subject(:store) { described_class.new(server_name: "chat/cut", home: home) }

  after { FileUtils.rm_rf(home) }

  it "stores credentials outside mcp.json with mode 0600" do
    store.save("access_token" => "access", "refresh_token" => "refresh")

    expect(store.load.fetch("access_token")).to eq("access")
    expect(File.stat(store.path).mode & 0o777).to eq(0o600)
    expect(store.path).to match(%r{mcp/oauth/chat_cut-[0-9a-f]{12}\.json\z})
  end

  it "atomically replaces credentials without temporary files" do
    store.save("access_token" => "old")
    store.save("access_token" => "new")

    expect(store.load.fetch("access_token")).to eq("new")
    expect(Dir.glob("#{store.path}.tmp-*")).to be_empty
  end

  it "deletes a grant" do
    store.save("access_token" => "access")

    store.delete

    expect(store.load).to be_nil
  end

  it "reports malformed credentials without their contents" do
    FileUtils.mkdir_p(File.dirname(store.path))
    File.write(store.path, '{"access_token":"do-not-leak"')

    expect { store.load }.to raise_error(described_class::Error, /invalid OAuth credential file/)
    begin
      store.load
    rescue described_class::Error => e
      expect(e.message).not_to include("do-not-leak")
    end
  end

  it "does not expose credentials from inspect" do
    store.save("access_token" => "do-not-leak")

    expect(store.inspect).not_to include("do-not-leak")
  end

  it "does not collide when different server names sanitize the same way" do
    other = described_class.new(server_name: "chat?cut", home: home)

    expect(other.path).not_to eq(store.path)
  end
end
