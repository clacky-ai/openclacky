# frozen_string_literal: true

ENV["CLACKY_TEST"] = "1"
ENV["CLACKY_TELEMETRY"] = "0"

require_relative "support/coverage"

# Redirect billing writes away from ~/.clacky/billing/ during test runs
require "tmpdir"
ENV["CLACKY_BILLING_DIR"] = Dir.mktmpdir("clacky_billing_test")

require "clacky"
require "clacky/server/project_manager"
require "fileutils"
require "climate_control"
require_relative "support/test_helpers"

TEST_PROJECTS_FILE = File.join(Dir.mktmpdir("clacky_projects_test"), "projects.json")

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  # Prevent background brand-skill sync threads from making real network calls
  # during tests. BrandConfig#sync_brand_skills_async! launches a Thread that
  # hits the remote API; stub it out globally so every Agent.new is fast.
  config.before(:each) do
    allow_any_instance_of(Clacky::BrandConfig).to receive(:sync_brand_skills_async!)
  end

  # Last-resort guard: a spec that builds a ProjectManager without injecting a
  # path would otherwise write into the developer's real ~/.clacky/projects.json.
  config.before(:suite) do
    Clacky::Server::ProjectManager.send(:remove_const, :PROJECTS_FILE)
    Clacky::Server::ProjectManager.const_set(:PROJECTS_FILE, TEST_PROJECTS_FILE)
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Exclude smoke tests from the default test run — they make real network requests.
  # Run explicitly with: bundle exec rspec spec/integration/ --tag smoke
  config.filter_run_excluding :smoke
end
