# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :spec do
  desc "Run the suite in parallel across CPU cores"
  task :parallel do
    sh "bundle exec parallel_rspec spec"
  end
end

desc "Run the suite with coverage (HTML report in coverage/index.html)"
task :coverage do
  ENV["COVERAGE"] = "1"
  rm_rf "coverage"
  sh "bundle exec parallel_rspec spec"
end


namespace :build do
  desc "Build both openclacky and clacky gems"
  task :all do
    puts "Building openclacky gem..."
    sh "gem build openclacky.gemspec"

    puts "Building clacky gem..."
    sh "cd clacky-legacy && gem build clacky.gemspec"
    sh "cd clacky-legacy && gem build clarky.gemspec"

    puts "Moving gems to pkg directory..."
    sh "mkdir -p pkg"
    sh "mv openclacky-*.gem pkg/"
    sh "mv clacky-legacy/*.gem pkg/"

    puts "✅ Build complete! Gems are in pkg/ directory:"
    sh "ls -lh pkg/*.gem"
  end

  desc "Clean built gems from pkg directory"
  task :clean do
    sh "rm -rf pkg/*.gem"
    puts "✅ Cleaned pkg directory"
  end
end

task default: %i[spec]
