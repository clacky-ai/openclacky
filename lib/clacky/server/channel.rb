# frozen_string_literal: true

# Channel layer — bridges Server Sessions to IM platforms (Feishu, WeCom, etc.)
#
# Load order:
#   1. Adapter base & registry
#   2. Platform adapters (each self-registers via Adapters.register)
#   3. ChannelConfig (IM platform credentials)
#   4. ChannelUIController (UIInterface impl that sends to IM)
#   5. ChannelManager (orchestrates adapters + sessions, in-memory session map)
#
# Usage in HttpServer:
#   require_relative "channel"
#   @channel_manager = Clacky::Channel::ChannelManager.new(
#     session_registry: @registry,
#     session_builder:  method(:build_session),
#     channel_config:   Clacky::ChannelConfig.load
#   )
#   @channel_manager.start

require_relative "channel/adapters/base"

# Load platform adapters (each registers itself)
require_relative "channel/adapters/feishu/adapter"
require_relative "channel/adapters/wecom/adapter"
require_relative "channel/adapters/weixin/adapter"
require_relative "channel/adapters/discord/adapter"
require_relative "channel/adapters/telegram/adapter"
require_relative "channel/adapters/dingtalk/adapter"
require_relative "channel/adapters/qq/adapter"

require_relative "channel/channel_config"
require_relative "channel/channel_ui_controller"
require_relative "channel/channel_manager"

# Discover and load user-defined adapters from ~/.clacky/channels/.
# Must run after the bundled adapters so user adapters can extend or override.
require_relative "channel/user_adapter_loader"
Clacky::Channel::Adapters::UserAdapterLoader.load_all

# Discover and load adapters contributed by ext.yml containers
# (contributes.channels). Runs last so any platform_id collision is won by
# user adapters, which is consistent with the override priority elsewhere.
require_relative "channel/extension_adapter_loader"
Clacky::Channel::Adapters::ExtensionAdapterLoader.load_all
