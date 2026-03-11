# frozen_string_literal: true

ENV["CLACKY_TEST"] = "1"

require "clacky"
require "tmpdir"
require "fileutils"
require "climate_control"
require_relative "support/test_helpers"

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

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
