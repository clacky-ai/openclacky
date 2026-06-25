# frozen_string_literal: true

module Clacky
  module Locales
    EN = {
      "llm.error.insufficient_credit"   => "Insufficient credit, please top up your account to continue",
      "llm.error.rate_limit_400"        => "Rate limit or service issue, retrying...",
      "llm.error.invalid_api_key"       => "Invalid API key, please check your configuration",
      "llm.error.403.model_not_allowed" => "This model is not available on your current plan",
      "llm.error.403.api_key_revoked"   => "API key has been revoked, please generate a new one",
      "llm.error.403.api_key_expired"   => "API key has expired, please generate a new one",
      "llm.error.403.quota_exceeded"    => "Quota exceeded, please upgrade your plan",
      "llm.error.403.access_denied"     => "Access denied, please check your API key permissions",
      "llm.error.403.default"           => "Access denied",
      "llm.error.endpoint_not_found"    => "API endpoint not found, please check your service URL",
      "llm.error.rate_limit_429"        => "Rate limit exceeded, please wait a moment",
      "llm.error.server_error"          => "Service temporarily unavailable (%<status>d), retrying...",
      "llm.error.unexpected"            => "Unexpected error (%<status>d)",
      "llm.error.html_response"         => "Service temporarily unavailable (received HTML error page), retrying...",
      "llm.error.bad_request"           => "Bad request: invalid parameters. Please check your model configuration",
      "llm.error.request_timeout"       => "Request timed out after %<retries>d retries",
      "llm.error.network_failed"        => "Network connection failed after %<retries>d retries",
      "llm.error.service_unavailable"   => "Service unavailable after %<retries>d retries"
    }.freeze
  end
end
