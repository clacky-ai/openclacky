# frozen_string_literal: true

require "fileutils"
require_relative "../hooks/advisor"

# Advisor extension HTTP API, mounted at /api/ext/advisor/.
# The WebUI close button calls /disable so the recommendation card stops
# appearing; /enable restores it. The choice is persisted in
# ~/.clacky/advisor.yml and honoured by the hooks on the next round.
class AdvisorExt < Clacky::ApiExtension
  # GET /api/ext/advisor/status
  get "/status" do
    json(enabled: Clacky::Advisor.enabled?)
  end

  # POST /api/ext/advisor/disable
  post "/disable" do
    Clacky::Advisor.set_enabled(false)
    json(enabled: false)
  end

  # POST /api/ext/advisor/enable
  post "/enable" do
    Clacky::Advisor.set_enabled(true)
    json(enabled: true)
  end
end
