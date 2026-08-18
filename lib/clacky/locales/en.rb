# frozen_string_literal: true

module Clacky
  module Locales
    EN = {
      "phase.skill_evolution"           => "Reflecting on this task",
      "phase.memory_update"             => "Updating long-term memory",
      "llm.error.insufficient_credit"   => "Insufficient credit, please top up your account to continue",
      "llm.error.rate_limit_400"        => "Rate limit or service issue, retrying...",
      "llm.error.invalid_api_key"       => "API key is invalid or expired, please update it in Settings",
      "llm.error.403.model_not_allowed" => "This model is not available on your current plan",
      "llm.error.403.api_key_revoked"   => "API key has been revoked, please generate a new one",
      "llm.error.403.api_key_expired"   => "API key has expired, please generate a new one",
      "llm.error.403.quota_exceeded"    => "API key quota exceeded. Please update the quota or disable the limit in the admin console",
      "llm.error.403.access_denied"     => "Access denied, please check your API key permissions",
      "llm.error.403.default"           => "Access denied",
      "llm.error.endpoint_not_found"    => "API endpoint not found, please check your service URL",
      "llm.error.rate_limit_429"        => "Rate limit exceeded, please wait a moment",
      "llm.error.quota_exhausted"       => "API quota exhausted (key usage limit reached). Please raise the quota or upgrade your plan in the console",
      "llm.error.server_error"          => "Service temporarily unavailable (%<status>d), retrying...",
      "llm.error.unexpected"            => "Unexpected error (%<status>d)",
      "llm.error.html_response"         => "Service temporarily unavailable (received HTML error page), retrying...",
      "llm.error.bad_request"           => "Bad request: invalid parameters. Please check your model configuration",
      "llm.error.request_timeout"       => "Request timed out after %<retries>d retries",
      "llm.error.network_failed"        => "Network connection failed after %<retries>d retries",
      "llm.error.service_unavailable"   => "Service unavailable after %<retries>d retries",
      "llm.warn.switching_to_fallback_url" => "Primary endpoint unreachable. Switching to fallback gateway: %<url>s",
      "platform.error.invalid_proof"        => "Invalid license key — please check and try again.",
      "platform.error.invalid_signature"    => "Invalid request signature.",
      "platform.error.nonce_replayed"       => "Duplicate request detected. Please try again.",
      "platform.error.timestamp_expired"    => "System clock is out of sync. Please adjust your time settings.",
      "platform.error.license_revoked"      => "This license has been revoked. Please contact support.",
      "platform.error.license_expired"      => "This license has expired. Please renew to continue.",
      "platform.error.device_limit_reached" => "Device limit reached for this license.",
      "platform.error.device_revoked"       => "This device has been revoked from the license. To re-activate, please wait 15 minutes and try again.",
      "platform.error.invalid_license"      => "License key not found. Please verify the key.",
      "platform.error.device_not_found"     => "Device not registered. Please re-activate.",
      "platform.error.contributor_required" => "Publishing extensions requires becoming a contributor. Sign in, open \"My Extensions\", and click \"Become a contributor\" (no review needed).",
      "platform.error.missing_device_token" => "This device is not bound to a platform account. Authorize it before publishing.",
      "platform.error.invalid_device_token" => "Device authorization is invalid. Please re-authorize this device.",
      "platform.error.device_token_revoked" => "This device's authorization has been revoked. Please re-authorize before publishing.",
      "platform.error.device_token_expired" => "This device's authorization has expired. Please re-authorize before publishing.",
      "platform.error.owner_user_not_found" => "No account found for this device. Please re-authorize it.",
      "platform.error.generic"              => "Request failed (HTTP %<code>s). Please contact support.",
      "platform.error.generic_with_code"    => "Request failed (HTTP %<code>s, code: %<error_code>s). Please contact support."
    }.freeze
  end
end
