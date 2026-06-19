#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky PDF Parser — CLI interface
#
# Usage:
#   ruby pdf_parser.rb <file_path>
#
# Output:
#   stdout — extracted text content (UTF-8)
#   stderr — error / progress messages
#   exit 0 — success
#   exit 1 — hard failure (file unreadable, pdftotext missing, etc.)
#
# Strategy
# --------
# PDF pages naturally fall into two kinds: pages with a real text layer,
# and scanned-image pages. The right tool is a per-page property, not a
# document-level one. So:
#
#   1. Run pdftotext once over the whole file (`-layout`), split by `\f`.
#   2. Pages with enough bytes → emit text directly.
#   3. Pages below threshold → list page numbers in a Notice section
#      with a shell command template the agent can run on demand to
#      render a specific page to PNG, then file_reader that PNG.
#
# The parser does NOT pre-render images. Most weak pages will never be
# read (the answer is often already in the text-layer pages). Rendering
# all of them up front is wasteful — 55 pages takes ~14s and most goes
# to waste. The agent decides when (and which page) to OCR based on the
# user's actual question.
#
# VERSION: 6

require "open3"

MIN_PAGE_BYTES = 20

def die(msg)
  warn msg
  exit 1
end

def pdftotext_pages(path)
  stdout, stderr, status = Open3.capture3(
    "pdftotext", "-layout", "-enc", "UTF-8", path, "-"
  )
  unless status.success?
    warn "pdftotext failed: #{stderr.strip}"
    return nil
  end
  pages = stdout.split("\f", -1)
  pages.pop if pages.last && pages.last.strip.empty?
  pages.map(&:strip)
rescue Errno::ENOENT
  warn "pdftotext not found. Install poppler (`brew install poppler` / `apt install poppler-utils`)."
  nil
end

def main(argv)
  die "Usage: pdf_parser.rb <file_path>" if argv.empty?
  path = argv[0]
  die "File not found: #{path}" unless File.file?(path)

  pages = pdftotext_pages(path)
  die "Could not extract text from PDF." if pages.nil?

  weak = []
  body_chunks = []
  pages.each_with_index do |text, idx|
    n = idx + 1
    if text.bytesize >= MIN_PAGE_BYTES
      body_chunks << "--- Page #{n} ---\n\n#{text}"
    else
      body_chunks << "--- Page #{n} ---\n\n[no extractable text layer]"
      weak << n
    end
  end

  output = body_chunks.join("\n\n")

  if weak.any?
    abs_path = File.expand_path(path)
    notice = +"\n\n--- Notice ---\n\n"
    notice << "#{weak.size} of #{pages.size} pages have no extractable text layer "
    notice << "(likely scanned images).\n"
    notice << "Pages without text: #{weak.join(', ')}\n\n"
    notice << "To OCR a specific page, render it to PNG via shell, then "
    notice << "file_reader the PNG (it will be transcribed via the "
    notice << "vision/OCR pipeline):\n\n"
    notice << "  pdftoppm -r 150 -f <N> -l <N> -png -singlefile "
    notice << "#{abs_path.inspect} /tmp/clacky-pdf-page-<N>\n"
    notice << "  # produces /tmp/clacky-pdf-page-<N>.png\n\n"
    notice << "Only render pages you actually need. If the user's question "
    notice << "is already answered by the extracted text above, skip OCR.\n"
    output << notice
  end

  $stdout.write(output)
  $stdout.write("\n") unless output.end_with?("\n")
  exit 0
end

main(ARGV) if __FILE__ == $PROGRAM_NAME
