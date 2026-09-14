# frozen_string_literal: true

require_relative "../runtime"

# Safe readiness endpoint for the bundled Codex provider. Authentication and
# ACP session actions are added by the runtime implementation slice.
class CodexExt < Clacky::ApiExtension
  class << self
    def status_payload(home_result:, launcher_result:)
      payload = {
        available: launcher_result.available?,
        status: launcher_result.available? ? "ready" : "unavailable",
        authenticated: nil,
        auth_reused: home_result.auth_reused == true,
        auth_reason: home_result.auth_reason
      }
      payload[:launcher] = launcher_result.source.to_s if launcher_result.source
      payload[:version] = launcher_result.version if launcher_result.version
      payload[:error_code] = launcher_result.error_code if launcher_result.error_code
      payload[:message] = launcher_result.message if launcher_result.message
      payload
    end
  end

  get "/status", timeout: 10, same_origin: true do
    json(Clacky::DefaultExtensions::Codex::Runtime.passive_status)
  end

  post "/connect", timeout: 310, same_origin: true do
    json(Clacky::DefaultExtensions::Codex::Runtime.status)
  end

  post "/authenticate", timeout: 310, same_origin: true do
    result = Clacky::DefaultExtensions::Codex::Runtime.authenticate_async
    json(result, status: result[:started] ? 202 : 200)
  end

  post "/discover", timeout: 310, same_origin: true do
    json(Clacky::DefaultExtensions::Codex::Runtime.discover_models)
  end
end
