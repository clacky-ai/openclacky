# frozen_string_literal: true

require "spec_helper"
require "clacky/mcp/oauth/session"

RSpec.describe Clacky::Mcp::OAuth::Session do
  class MemoryStore
    attr_reader :saved

    def initialize(value = nil)
      @value = value
    end

    def load
      @value && @value.dup
    end

    def save(value)
      @saved = value.dup
      @value = value.dup
    end

    def delete
      @value = nil
    end
  end

  class FakeManager
    attr_reader :refreshes, :logins

    def initialize(store, now)
      @store = store
      @now = now
      @refreshes = 0
      @logins = 0
    end

    def login
      @logins += 1
      @store.save("access_token" => "logged-in", "refresh_token" => "refresh", "expires_at" => @now + 3600)
    end

    def refresh(grant)
      @refreshes += 1
      grant.merge("access_token" => "fresh", "refresh_token" => "rotated", "expires_at" => @now + 3600)
    end
  end

  let(:now) { 1_800_000_000 }

  it "reuses a valid access token" do
    store = MemoryStore.new("access_token" => "valid", "expires_at" => now + 3600)
    manager = FakeManager.new(store, now)

    headers = described_class.new(store: store, manager: manager, clock: -> { now }).authorization_headers

    expect(headers).to eq("Authorization" => "Bearer valid")
    expect(manager.refreshes).to eq(0)
  end

  it "refreshes within the expiry skew and persists rotation" do
    store = MemoryStore.new("access_token" => "old", "refresh_token" => "refresh", "expires_at" => now + 30)
    manager = FakeManager.new(store, now)
    session = described_class.new(store: store, manager: manager, clock: -> { now })

    expect(session.authorization_headers).to eq("Authorization" => "Bearer fresh")
    expect(store.saved.fetch("refresh_token")).to eq("rotated")
    expect(manager.refreshes).to eq(1)
  end

  it "forces one refresh after transport invalidation" do
    store = MemoryStore.new("access_token" => "valid", "refresh_token" => "refresh", "expires_at" => now + 3600)
    manager = FakeManager.new(store, now)
    session = described_class.new(store: store, manager: manager, clock: -> { now })

    session.invalidate!

    expect(session.authorization_headers.fetch("Authorization")).to eq("Bearer fresh")
    expect(manager.refreshes).to eq(1)
  end

  it "requires explicit login when no grant exists" do
    store = MemoryStore.new
    manager = FakeManager.new(store, now)

    expect do
      described_class.new(store: store, manager: manager, clock: -> { now }).authorization_headers
    end.to raise_error(described_class::NotConnectedError, /mcp login/)
  end

  it "delegates login and logout" do
    store = MemoryStore.new
    manager = FakeManager.new(store, now)
    session = described_class.new(store: store, manager: manager, clock: -> { now })

    session.login
    expect(session).to be_connected
    session.logout
    expect(session).not_to be_connected
  end

  it "does not expose tokens from inspect" do
    store = MemoryStore.new("access_token" => "do-not-leak", "expires_at" => now + 3600)
    session = described_class.new(store: store, manager: FakeManager.new(store, now), clock: -> { now })

    expect(session.inspect).not_to include("do-not-leak")
  end
end
