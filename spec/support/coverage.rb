# frozen_string_literal: true

# Coverage is opt-in: `COVERAGE=1 bundle exec rspec` or `rake coverage`.
return unless ENV["COVERAGE"] == "1"

require "simplecov"

SimpleCov.start do
  enable_coverage :branch

  add_filter %r{^/spec/}
  add_filter %r{^/tmp/}
  add_filter %r{^/vendor/}
  # Shipped as assets and executed as standalone subprocesses, never loaded
  # into the test process — counting them only dilutes the signal.
  add_filter %r{^/lib/clacky/default_skills/}
  add_filter %r{^/lib/clacky/default_parsers/}

  add_group "Agent",      "lib/clacky/agent"
  add_group "Tools",      "lib/clacky/tools"
  add_group "Server",     "lib/clacky/server"
  add_group "UI",         %w[lib/clacky/ui2 lib/clacky/rich_ui_controller.rb]
  add_group "Channels",   "lib/clacky/channel"
  add_group "Utils",      "lib/clacky/utils"
  add_group "Extensions", "lib/clacky/extensions"

  track_files "lib/**/*.rb"

  minimum_coverage line: Float(ENV.fetch("COVERAGE_MIN_LINE", 0))

  if ENV["TEST_ENV_NUMBER"]
    command_name "rspec-#{ENV['TEST_ENV_NUMBER'].to_s.empty? ? 1 : ENV['TEST_ENV_NUMBER']}"
    # Each parallel worker writes its own resultset; the merge window must
    # outlive the whole suite or early workers get dropped from the report.
    merge_timeout 3600
  end
end
