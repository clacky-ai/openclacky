# frozen_string_literal: true

require "open3"
require "tmpdir"

# Helpers for running external syntax checkers
module SyntaxChecker
  # Check JavaScript syntax using `node --check`.
  # Returns { valid: true/false, output: String }
  def self.check_js(path)
    stdout, stderr, status = Open3.capture3("node", "--check", path)
    output = (stdout + stderr).strip
    { valid: status.exitstatus == 0, output: output }
  end

  # Check HTML syntax using a pure-Ruby structural validator.
  # Validates: DOCTYPE presence, balanced tags, basic well-formedness.
  # Uses Ruby's REXML or structural checks rather than the old `tidy` tool
  # which doesn't support HTML5 elements (<aside>, <main>, <header>, <svg>, etc.)
  # and chokes on Unicode characters.
  def self.check_html(path)
    content = File.read(path, encoding: "utf-8")
    errors = []

    # Check for DOCTYPE
    errors << "Missing DOCTYPE declaration" unless content.match?(/<!DOCTYPE\s+html/i)

    # Check for <html> tag
    errors << "Missing <html> element" unless content.match?(/<html/i)

    # Check for unclosed tags using a simple structural balance check.
    # Void elements that don't need closing tags (HTML5 spec).
    void_elements = %w[area base br col embed hr img input link meta param source track wbr]

    # Extract all tags (open, close, self-closing) — skip comments, scripts, styles
    stripped = content
      .gsub(/<!--.*?-->/m, "")  # remove comments
      .gsub(/<script\b[^>]*>.*?<\/script>/im, "")  # remove script content
      .gsub(/<style\b[^>]*>.*?<\/style>/im, "")    # remove style content

    stack = []
    stripped.scan(/<\/?([a-zA-Z][a-zA-Z0-9]*)(\s[^>]*)?(\/?)>/m) do |tag, _attrs, self_close|
      tag_name = tag.downcase
      next if void_elements.include?(tag_name)
      next if self_close == "/"

      full_match = $~[0]
      if full_match.start_with?("</")
        # Closing tag
        if stack.last == tag_name
          stack.pop
        elsif stack.include?(tag_name)
          # Pop until we find our match (handles optional closing tags)
          stack.pop while stack.last != tag_name
          stack.pop
        end
        # If not in stack at all, it may be an extra closing tag — ignore for leniency
      else
        stack.push(tag_name)
      end
    end

    errors << "Unclosed tags: #{stack.join(", ")}" unless stack.empty?

    output = errors.join("\n")
    { valid: errors.empty?, output: output, exit_code: errors.empty? ? 0 : 1 }
  end

  # Check CSS syntax using a Ruby-based structural validator.
  # Validates: balanced braces, non-empty selectors, basic property syntax.
  # Returns { valid: true/false, errors: [String] }
  def self.check_css(content)
    errors = []
    errors.concat(check_css_braces(content))
    errors.concat(check_css_empty_selectors(content))
    errors.concat(check_css_property_syntax(content))
    { valid: errors.empty?, errors: errors }
  end

  private_class_method def self.check_css_braces(content)
    errors = []
    depth = 0
    content.each_char.with_index(1) do |ch, _i|
      case ch
      when "{" then depth += 1
      when "}"
        depth -= 1
        errors << "Unexpected closing brace '}'" if depth < 0
      end
    end
    errors << "Unclosed brace: #{depth} opening brace(s) not closed" if depth > 0
    errors
  end

  private_class_method def self.check_css_empty_selectors(content)
    errors = []
    # Strip comments first to avoid false positives inside /* ... */
    stripped = content.gsub(%r{/\*.*?\*/}m, "")
    # Find empty rule blocks: selector { } with no declarations
    stripped.scan(/([^{}]+)\{\s*\}/) do |match|
      selector = match[0].strip
      # Skip @-rules like @charset, @import used inline
      next if selector.start_with?("@")
      next if selector.empty?

      errors << "Empty rule block for selector: '#{selector.lines.last&.strip}'"
    end
    errors
  end

  private_class_method def self.check_css_property_syntax(content)
    errors = []
    stripped = content.gsub(%r{/\*.*?\*/}m, "")
    in_block = false
    line_num = 0

    stripped.each_line do |line|
      line_num += 1
      in_block = true if line.include?("{")
      in_block = false if line.include?("}")

      next unless in_block

      trimmed = line.strip
      # Skip blank lines, opening/closing braces, at-rules inside blocks, and comments
      next if trimmed.empty?
      next if trimmed.start_with?("{", "}", "//", "/*", "*", "@")
      next if trimmed.include?("{") || trimmed.include?("}")

      # A CSS declaration must contain a colon
      unless trimmed.include?(":")
        errors << "Line #{line_num}: possible missing colon in declaration: '#{trimmed}'"
      end
    end
    errors
  end
end

RSpec.describe "Web asset syntax" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }

  # ─── JavaScript ────────────────────────────────────────────────────────────

  describe "JavaScript syntax" do
    let(:js_files) { Dir[File.join(web_dir, "**", "*.js")].reject { |f| f.include?("/vendor/") } }

    it "finds JavaScript files to test" do
      expect(js_files).not_to be_empty, "No .js files found in #{web_dir}"
    end

    it "all .js files pass node --check" do
      # One `node --check` process per file; 49 serial spawns is ~1.7s, so
      # fan them out.
      results = js_files.map { |f| [f, Thread.new { SyntaxChecker.check_js(f) }] }
                        .map { |f, t| [f, t.value] }

      aggregate_failures "javascript syntax errors" do
        results.each do |file, result|
          expect(result[:valid]).to be(true),
            "Syntax error in #{File.basename(file)}:\n#{result[:output]}"
        end
      end
    end

    context "with intentionally invalid JavaScript" do
      it "detects a missing closing parenthesis" do
        Dir.mktmpdir do |dir|
          bad_js = File.join(dir, "bad.js")
          File.write(bad_js, "function broken( {\n  return 1;\n}\n")
          result = SyntaxChecker.check_js(bad_js)
          expect(result[:valid]).to be(false)
          expect(result[:output]).to match(/SyntaxError/i)
        end
      end

      it "detects an unexpected token" do
        Dir.mktmpdir do |dir|
          bad_js = File.join(dir, "bad.js")
          File.write(bad_js, "const x = ;\n")
          result = SyntaxChecker.check_js(bad_js)
          expect(result[:valid]).to be(false)
          expect(result[:output]).to match(/SyntaxError/i)
        end
      end

      it "detects an unclosed string literal" do
        Dir.mktmpdir do |dir|
          bad_js = File.join(dir, "bad.js")
          File.write(bad_js, "const msg = \"hello world;\n")
          result = SyntaxChecker.check_js(bad_js)
          expect(result[:valid]).to be(false)
        end
      end

      it "accepts valid JavaScript" do
        Dir.mktmpdir do |dir|
          good_js = File.join(dir, "good.js")
          File.write(good_js, <<~JS)
            // Valid JavaScript
            function greet(name) {
              return `Hello, ${name}!`;
            }
            const result = greet("world");
            console.log(result);
          JS
          result = SyntaxChecker.check_js(good_js)
          expect(result[:valid]).to be(true), result[:output]
        end
      end
    end
  end

  # ─── HTML ──────────────────────────────────────────────────────────────────

  describe "HTML syntax" do
    let(:html_files) { Dir[File.join(web_dir, "*.html")] }

    it "finds HTML files to test" do
      expect(html_files).not_to be_empty, "No .html files found in #{web_dir}"
    end

    it "all .html files produce no tidy errors (exit 0)" do
      aggregate_failures "html syntax errors" do
        html_files.each do |file|
          result = SyntaxChecker.check_html(file)
          expect(result[:valid]).to be(true),
            "tidy reported issues in #{File.basename(file)} (exit #{result[:exit_code]}):\n#{result[:output]}"
        end
      end
    end

    context "with intentionally invalid HTML" do
      it "detects an unclosed tag" do
        Dir.mktmpdir do |dir|
          bad_html = File.join(dir, "bad.html")
          File.write(bad_html, <<~HTML)
            <!DOCTYPE html>
            <html lang="en">
            <head><title>Bad</title></head>
            <body>
            <div>
          HTML
          result = SyntaxChecker.check_html(bad_html)
          # tidy exits 1 when it finds structural issues
          expect(result[:valid]).to be(false)
        end
      end

      it "detects a missing DOCTYPE" do
        Dir.mktmpdir do |dir|
          bad_html = File.join(dir, "nodoctype.html")
          File.write(bad_html, <<~HTML)
            <html lang="en">
            <head><title>No DOCTYPE</title></head>
            <body><p>Hello</p></body>
            </html>
          HTML
          result = SyntaxChecker.check_html(bad_html)
          expect(result[:valid]).to be(false)
        end
      end

      it "accepts well-formed HTML" do
        Dir.mktmpdir do |dir|
          good_html = File.join(dir, "good.html")
          File.write(good_html, <<~HTML)
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
              <title>Valid Page</title>
            </head>
            <body>
              <h1>Hello</h1>
              <p>World</p>
            </body>
            </html>
          HTML
          result = SyntaxChecker.check_html(good_html)
          expect(result[:valid]).to be(true), result[:output]
        end
      end
    end
  end

  # ─── CSS ───────────────────────────────────────────────────────────────────

  describe "CSS syntax" do
    let(:css_files) { Dir[File.join(web_dir, "*.css")] }

    it "finds CSS files to test" do
      expect(css_files).not_to be_empty, "No .css files found in #{web_dir}"
    end

    it "all .css files have balanced braces" do
      aggregate_failures "css brace balance" do
        css_files.each do |file|
          content = File.read(file)
          result = SyntaxChecker.check_css(content)
          brace_errors = result[:errors].select { |e| e.include?("brace") }
          expect(brace_errors).to be_empty,
            "Brace mismatch in #{File.basename(file)}:\n#{brace_errors.join("\n")}"
        end
      end
    end

    it "all .css files have no empty rule blocks" do
      aggregate_failures "css empty selectors" do
        css_files.each do |file|
          content = File.read(file)
          result = SyntaxChecker.check_css(content)
          empty_errors = result[:errors].select { |e| e.include?("Empty rule block") }
          expect(empty_errors).to be_empty,
            "Empty rule blocks in #{File.basename(file)}:\n#{empty_errors.join("\n")}"
        end
      end
    end

    context "with intentionally invalid CSS" do
      it "detects an unclosed brace" do
        css = "body {\n  color: red;\n\np { color: blue; }\n"
        result = SyntaxChecker.check_css(css)
        expect(result[:valid]).to be(false)
        expect(result[:errors].join).to match(/brace/i)
      end

      it "detects an unexpected extra closing brace" do
        css = "body { color: red; }}\n"
        result = SyntaxChecker.check_css(css)
        expect(result[:valid]).to be(false)
        expect(result[:errors].join).to match(/closing brace/i)
      end

      it "detects an empty selector block" do
        css = ".unused { }\n"
        result = SyntaxChecker.check_css(css)
        expect(result[:valid]).to be(false)
        expect(result[:errors].join).to match(/Empty rule block/)
      end

      it "accepts valid CSS" do
        css = <<~CSS
          /* Reset */
          * { box-sizing: border-box; }

          body {
            font-family: sans-serif;
            background: #fff;
            color: #333;
          }

          .container {
            max-width: 1200px;
            margin: 0 auto;
          }
        CSS
        result = SyntaxChecker.check_css(css)
        expect(result[:valid]).to be(true), result[:errors].join("\n")
      end

      it "ignores comments when checking for empty blocks" do
        css = "/* body { } this is a comment */ body { color: red; }\n"
        result = SyntaxChecker.check_css(css)
        empty_errors = result[:errors].select { |e| e.include?("Empty rule block") }
        expect(empty_errors).to be_empty
      end
    end
  end
end
