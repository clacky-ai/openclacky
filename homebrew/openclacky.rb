# frozen_string_literal: true

class Openclacky < Formula
  desc "Command-line interface for AI models with autonomous agent capabilities"
  homepage "https://github.com/clacky-ai/open-clacky"
  url "https://rubygems.org/downloads/openclacky-0.6.1.gem"
  sha256 "" # Will be updated when gem is published
  license "MIT"

  depends_on "ruby@3.3"

  def install
    ENV["GEM_HOME"] = libexec
    system "gem", "install", cached_download, "--no-document"
    
    # Create wrapper scripts
    (bin/"openclacky").write_env_script libexec/"bin/openclacky", GEM_HOME: ENV["GEM_HOME"]
    (bin/"clacky").write_env_script libexec/"bin/clacky", GEM_HOME: ENV["GEM_HOME"]
  end

  test do
    assert_match "openclacky version #{version}", shell_output("#{bin}/openclacky version")
  end
end
