# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../../artifact_store"

begin
  options = { height: 420, delete_source: false }
  OptionParser.new do |parser|
    parser.on("--title TITLE") { |value| options[:title] = value }
    parser.on("--height HEIGHT", Integer) { |value| options[:height] = value }
    parser.on("--delete-source") { options[:delete_source] = true }
  end.parse!

  path = ARGV.shift.to_s
  title = options[:title].to_s.gsub(/[]/, "").strip
  raise ArgumentError, "an HTML file path is required" if path.empty?
  raise ArgumentError, "--title cannot be empty" if title.empty?
  raise ArgumentError, "HTML file not found: #{path}" unless File.file?(path)

  html = File.binread(path).force_encoding(Encoding::UTF_8)
  stored = Clacky::ArtifactStore.new.write(html)
  height = [[options[:height], 240].max, 720].min
  payload = {
    artifact_id: stored[:id],
    title: title[0, 120],
    height: height
  }

  File.delete(path) if options[:delete_source]
  puts "visualize#{JSON.generate(payload)}"
rescue ArgumentError, Clacky::ArtifactStore::Error, SystemCallError => e
  warn "Failed to publish visualization: #{e.message}"
  exit 1
end
