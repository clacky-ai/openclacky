# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in openclacky.gemspec
gemspec

ruby_version = Gem::Version.new(RUBY_VERSION)

gem "irb" if ruby_version >= Gem::Version.new("2.7")

gem "rake", "~> 13.0"

gem "debug" if ruby_version >= Gem::Version.new("2.7")

gem "rspec", "~> 3.0"
if ruby_version < Gem::Version.new("2.7")
  gem "rubocop", ">= 1.21", "< 1.51"
else
  gem "rubocop", "~> 1.21"
end
gem "climate_control"

gem "ruby_rich", "~> 0.5.2" if ruby_version >= Gem::Version.new("2.6")

gem "cgi" if ruby_version >= Gem::Version.new("4.0")
