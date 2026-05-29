#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky WPS Parser — CLI interface
#
# Handles WPS Office formats:
#   .wps — WPS Writer (word processor)
#   .et  — WPS Spreadsheet
#   .dps — WPS Presentation
#
# Usage:
#   ruby wps_parser.rb <file_path>
#
# Output:
#   stdout — extracted text content (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# VERSION: 1

require "open3"
require "tmpdir"
require "fileutils"

MIN_CONTENT_BYTES = 20

# Convert WPS formats to text using LibreOffice headless mode.
# .et (spreadsheet) → csv for structured output; .wps/.dps → txt.
def try_libreoffice(path, ext)
  Dir.mktmpdir("clacky-wps") do |dir|
    output_ext = ext == ".et" ? "csv" : "txt"
    _stdout, _stderr, status = Open3.capture3(
      "libreoffice", "--headless", "--convert-to", output_ext,
      "--outdir", dir, path
    )
    return nil unless status.success?

    output_file = Dir.glob(File.join(dir, "*.#{output_ext}")).first
    return nil unless output_file && File.exist?(output_file)

    text = File.read(output_file).strip
    return nil if text.bytesize < MIN_CONTENT_BYTES
    text
  end
rescue Errno::ENOENT
  nil
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby wps_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

ext = File.extname(path).downcase

unless %w[.wps .et .dps].include?(ext)
  warn "Unsupported WPS format: #{ext}"
  exit 1
end

text = try_libreoffice(path, ext)

if text
  print text
  exit 0
else
  warn "Could not extract text from #{ext} file."
  warn "Tip: install LibreOffice to enable WPS format support."
  warn "  macOS:  brew install --cask libreoffice"
  warn "  Linux:  apt install libreoffice"
  exit 1
end
