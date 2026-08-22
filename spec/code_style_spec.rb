# frozen_string_literal: true

# Find all Ruby source files under lib/ and bin/
RUBY_SOURCE_FILES = Dir.glob(File.expand_path("../../{lib,bin}/**/*.rb", __FILE__)).sort.freeze

RSpec.describe "Code style: no standalone private keyword" do
  it "has at least one Ruby source file to check" do
    expect(RUBY_SOURCE_FILES).not_to be_empty
  end

  RUBY_SOURCE_FILES.each do |path|
    it "#{path.sub(Dir.pwd + "/", "")} has no standalone `private` keyword" do
      lines = File.readlines(path)
      violations = []

      lines.each_with_index do |line, index|
        # Match lines where `private` appears alone (possibly indented),
        # but NOT `private def`, `private attr_*`, `private_class_method`, etc.
        stripped = line.strip
        if stripped == "private" || stripped.match?(/^private\s*#/)
          violations << "  line #{index + 1}: #{line.rstrip}"
        end
      end

      expect(violations).to be_empty,
        "Found standalone `private` keyword — use `private def method_name` instead:\n#{violations.join("\n")}"
    end
  end
end

RSpec.describe "Code style: threads go through ThreadRegistry.spawn" do
  it "checks every Ruby source file for raw Thread.new" do
    expect(RUBY_SOURCE_FILES).not_to be_empty
  end

  RUBY_SOURCE_FILES.each do |path|
    it "#{path.sub(Dir.pwd + "/", "")} creates threads only via ThreadRegistry.spawn" do
      lines = File.readlines(path)
      violations = []

      lines.each_with_index do |line, index|
        next unless line.match?(/Thread\.new\b/)

        # ThreadRegistry.spawn itself is the one allowed user of Thread.new.
        next if path.end_with?("lib/clacky/thread_registry.rb")

        # Trap handlers cannot call ThreadRegistry.spawn: register() takes a
        # Mutex, and Mutex#synchronize raises ThreadError from trap context.
        next if line.match?(/Thread\.new \{ shutdown_proc\.call \}/)

        next if line.strip.start_with?("#") # comments only

        violations << "  line #{index + 1}: #{line.rstrip}"
      end

      expect(violations).to be_empty,
        "Found raw `Thread.new` — use `Clacky::ThreadRegistry.spawn(name: \"...\")` instead:\n#{violations.join("\n")}"
    end
  end
end
