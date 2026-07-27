# frozen_string_literal: true

module Clacky
  module Locales
    ZH = {
      "llm.error.insufficient_credit"   => "账户余额不足，请前往控制台充值后继续使用",
      "llm.error.rate_limit_400"        => "请求频率过高或服务暂时不可用，正在重试...",
      "llm.error.invalid_api_key"       => "API Key 无效或已过期，请到设置中重新配置",
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
      "llm.error.service_unavailable"   => "服务暂时不可用（已重试 %<retries>d 次）",
      "llm.warn.switching_to_fallback_url" => "主节点无法连接，正在切换到备用节点：%<url>s",
      "platform.error.invalid_proof"        => "许可证密钥无效，请检查后重试。",
      "platform.error.invalid_signature"    => "请求签名无效。",
      "platform.error.nonce_replayed"       => "检测到重复请求，请重试。",
      "platform.error.timestamp_expired"    => "系统时钟不同步，请校准本机时间后重试。",
      "platform.error.license_revoked"      => "该许可证已被吊销，请联系客服。",
      "platform.error.license_expired"      => "该许可证已过期，请续订后继续。",
      "platform.error.device_limit_reached" => "该许可证的设备数量已达上限。",
      "platform.error.device_revoked"       => "该设备已从许可证中移除。如需重新绑定，请等待 15 分钟后再试。",
      "platform.error.invalid_license"      => "未找到许可证密钥，请核对后重试。",
      "platform.error.device_not_found"     => "设备未注册，请重新激活。",
      "platform.error.contributor_required" => "发布扩展需要先成为扩展贡献者。请登录平台，打开「我的扩展」页面，点击「成为扩展贡献者」即可开通（无需审核）。",
      "platform.error.missing_device_token" => "当前设备未绑定平台账户，请先授权此设备后再发布。",
      "platform.error.invalid_device_token" => "设备授权已失效，请重新授权此设备。",
      "platform.error.device_token_revoked" => "此设备的授权已被撤销，请重新授权后再发布。",
      "platform.error.device_token_expired" => "此设备的授权已过期，请重新授权后再发布。",
      "platform.error.owner_user_not_found" => "未找到该设备对应的账户，请重新授权此设备。",
      "platform.error.generic"              => "请求失败（HTTP %<code>s），请联系客服。",
      "platform.error.generic_with_code"    => "请求失败（HTTP %<code>s，错误码：%<error_code>s），请联系客服。"
    }.freeze
  end
end
