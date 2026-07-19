# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # Identity stores the client's platform-account binding, separate from
  # BrandConfig (white-label / license). It holds the long-lived device token
  # issued by the RFC 8628 device-authorization flow, which proves creator
  # identity when publishing extensions to the marketplace.
  #
  # ~/.clacky/identity.yml structure:
  #   device_token: "clacky-dt-..."
  #   user_id: 42
  #   bound_at: "2026-07-05T00:00:00Z"
  class Identity
    CONFIG_DIR    = Clacky.data_dir
    IDENTITY_FILE = File.join(CONFIG_DIR, "identity.yml")

    attr_reader :device_token, :user_id, :bound_at

    def initialize(attrs = {})
      @device_token = attrs["device_token"]
      @user_id      = attrs["user_id"]
      @bound_at     = attrs["bound_at"]
    end

    def self.load
      data = File.exist?(IDENTITY_FILE) ? (YAML.safe_load(File.read(IDENTITY_FILE)) || {}) : {}
      new(data)
    rescue StandardError
      new({})
    end

    # True when this device has a device token bound to a platform account.
    def bound?
      !@device_token.nil? && !@device_token.to_s.strip.empty?
    end

    # Persist a fresh binding from a device-authorization approval.
    def bind!(device_token:, user_id:)
      @device_token = device_token
      @user_id      = user_id
      @bound_at     = Time.now.utc.iso8601
      save
      self
    end

    def clear!
      @device_token = nil
      @user_id      = nil
      @bound_at     = nil
      FileUtils.rm_f(IDENTITY_FILE)
    end

    def save
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(IDENTITY_FILE, to_yaml)
      FileUtils.chmod(0o600, IDENTITY_FILE)
    end

    private def to_yaml
      {
        "device_token" => @device_token,
        "user_id"      => @user_id,
        "bound_at"     => @bound_at
      }.compact.to_yaml
    end
  end
end
