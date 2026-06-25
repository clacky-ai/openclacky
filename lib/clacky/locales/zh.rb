# frozen_string_literal: true

module Clacky
  module Locales
    ZH = {
      "llm.error.insufficient_credit"   => "账户余额不足，请前往控制台充值后继续使用",
      "llm.error.rate_limit_400"        => "请求频率过高或服务暂时不可用，正在重试...",
      "llm.error.invalid_api_key"       => "API 密钥无效，请检查配置",
      "llm.error.403.model_not_allowed" => "当前模型不支持免费试用，请升级套餐或切换其他模型",
      "llm.error.403.api_key_revoked"   => "API 密钥已被撤销，请前往控制台重新生成",
      "llm.error.403.api_key_expired"   => "API 密钥已过期，请前往控制台重新生成",
      "llm.error.403.quota_exceeded"    => "配额已用完，请升级套餐",
      "llm.error.403.access_denied"     => "访问被拒绝，请检查 API 密钥权限",
      "llm.error.403.default"           => "访问被拒绝",
      "llm.error.endpoint_not_found"    => "API 端点不存在，请检查服务地址配置",
      "llm.error.rate_limit_429"        => "请求过于频繁，请稍候重试",
      "llm.error.server_error"          => "服务暂时不可用（%<status>d），正在重试...",
      "llm.error.unexpected"            => "请求失败（%<status>d）",
      "llm.error.html_response"         => "服务暂时不可用（收到 HTML 错误页），正在重试...",
      "llm.error.bad_request"           => "请求参数有误，请检查模型配置或重试",
      "llm.error.request_timeout"       => "请求超时（已重试 %<retries>d 次）",
      "llm.error.network_failed"        => "网络连接失败（已重试 %<retries>d 次）",
      "llm.error.service_unavailable"   => "服务暂时不可用（已重试 %<retries>d 次）"
    }.freeze
  end
end
