# frozen_string_literal: true

require "tmpdir"
require_relative "../agent_config"

module Clacky
  module Server
    # Shared directory policy for master lifecycle and CLI discovery.
    module PidFiles
      module_function

      def directory
        override = ENV["CLACKY_PID_DIR"]
        configured = if override && !override.strip.empty?
                       override
                     else
                       AgentConfig.load.pid_dir
                     end
        return Dir.tmpdir if configured.nil? || configured.strip.empty?

        File.expand_path(configured)
      end
    end
  end
end
