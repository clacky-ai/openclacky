#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require 'clacky'
require 'clacky/server/http_server'

agent_config = Clacky::AgentConfig.load
client_factory = lambda do
  entry = agent_config.current_model
  Clacky::Client.new(
    agent_config.api_key,
    base_url: agent_config.base_url,
    model: agent_config.model_name,
    anthropic_format: agent_config.anthropic_format?,
  )
end

server = Clacky::Server::HttpServer.new(
  host: '127.0.0.1',
  port: 3001,
  agent_config: agent_config,
  client_factory: client_factory,
)
server.start
