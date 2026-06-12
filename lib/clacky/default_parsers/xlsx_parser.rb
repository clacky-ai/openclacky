#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Clacky XLSX Parser — CLI interface
#
# Usage:
#   ruby xlsx_parser.rb <file_path>
#
# Output:
#   stdout — extracted content in Markdown tables (UTF-8)
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# Dependencies: rubyzip gem (gem install rubyzip)
#
# This file lives in ~/.clacky/parsers/ and can be modified by the LLM.
#
# Implementation note:
#   The worksheet/sharedStrings XML is parsed with REXML's *streaming*
#   (SAX) parser, NOT the DOM (REXML::Document) + XPath approach. A DOM
#   build of a multi-megabyte sheet costs O(n) memory and the XPath
#   queries used per-row turn the whole thing into O(n^2) — a 9 MB sheet
#   would hang for minutes. The streaming listeners below run in constant
#   memory and linear time, so large spreadsheets parse in seconds with
#   no external dependency (no Python / openpyxl needed).
#
# VERSION: 1

require "zip"
require "rexml/document"
require "rexml/streamlistener"
require "stringio"

# Convert a cell reference like "B3" / "AA12" into a zero-based column index.
# Returns nil when the ref is missing/unparseable, so callers can fall back
# to positional appending.
def column_index(ref)
  return nil unless ref
  letters = ref[/\A[A-Z]+/]
  return nil unless letters
  letters.each_char.reduce(0) { |acc, ch| acc * 26 + (ch.ord - 64) } - 1
end

# --- Streaming listener for xl/sharedStrings.xml ---
#
# Collects each <si> entry's concatenated text into an array indexed by
# position. An <si> may contain a single <t> or several <r><t> runs; we
# concatenate all <t> text within the current <si>.
class SharedStringsListener
  include REXML::StreamListener

  attr_reader :strings

  def initialize
    @strings = []
    @in_si = false
    @buf = +""
  end

  def tag_start(name, _attrs)
    local = name.sub(/\A.*:/, "")
    if local == "si"
      @in_si = true
      @buf = +""
    end
  end

  def text(data)
    @buf << data if @in_si
  end

  def tag_end(name)
    local = name.sub(/\A.*:/, "")
    if local == "si"
      @strings << @buf
      @in_si = false
      @buf = +""
    end
  end
end

# --- Streaming listener for a single worksheet ---
#
# Emits rows as arrays of strings. Cell type handling mirrors the OOXML
# spec:
#   t="s"        -> <v> is an index into the shared strings table
#   t="inlineStr"-> text lives in <is><t>...</t></is>, not <v>
#   t="str"      -> formula result string, in <v>
#   (default)    -> numeric/other, raw <v> text
#
# Column positions are honoured via each cell's "r" attribute (e.g. "C5")
# so that empty/skipped cells don't shift later columns left.
class SheetListener
  include REXML::StreamListener

  attr_reader :rows

  def initialize(shared_strings)
    @shared = shared_strings
    @rows = []
    @cur_row = nil       # Hash{col_index => value}
    @cell_type = nil
    @cell_col = nil
    @pending_v = nil
    @pending_is = nil
    @in_v = false
    @in_t = false
    @in_is = false
    @buf = +""
  end

  def tag_start(name, attrs)
    local = name.sub(/\A.*:/, "")
    case local
    when "row"
      @cur_row = {}
    when "c"
      @cell_type = attrs["t"]
      @cell_col = column_index(attrs["r"])
      @pending_v = nil
      @pending_is = nil
      @in_is = false
    when "is"
      @in_is = true
    when "v"
      @in_v = true
      @buf = +""
    when "t"
      @in_t = true
      @buf = +"" unless @in_v # inline-string <t>: start fresh
    end
  end

  def text(data)
    @buf << data if @in_v || @in_t
  end

  def tag_end(name)
    local = name.sub(/\A.*:/, "")
    case local
    when "v"
      @in_v = false
      @pending_v = @buf
    when "t"
      @in_t = false
      if @in_is
        # inline string run text — accumulate across multiple <r><t>
        (@pending_is ||= +"") << @buf
      end
    when "is"
      @in_is = false
    when "c"
      val =
        case @cell_type
        when "s"
          idx = @pending_v.to_s.strip
          idx.empty? ? "" : (@shared[idx.to_i] || "")
        when "inlineStr"
          @pending_is.to_s
        else
          @pending_v.to_s
        end
      unless @cur_row.nil?
        col = @cell_col || (@cur_row.keys.max ? @cur_row.keys.max + 1 : 0)
        @cur_row[col] = val
      end
      @pending_v = nil
      @pending_is = nil
      @cell_type = nil
      @cell_col = nil
    when "row"
      if @cur_row
        width = @cur_row.keys.max
        cells =
          if width.nil?
            []
          else
            (0..width).map { |i| @cur_row[i] || "" }
          end
        @rows << cells unless cells.all? { |c| c.to_s.empty? }
        @cur_row = nil
      end
    end
  end
end

def build_markdown_table(rows)
  col_count = rows.map(&:size).max
  lines = []
  rows.each_with_index do |row, i|
    padded = row + [""] * [col_count - row.size, 0].max
    lines << "| #{padded.join(" | ")} |"
    lines << "|#{" --- |" * col_count}" if i == 0
  end
  lines.join("\n")
end

# --- main ---

path = ARGV[0]

if path.nil? || path.empty?
  warn "Usage: ruby xlsx_parser.rb <file_path>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

begin
  body = File.binread(path)
  shared_strings = []
  sheet_names    = {}   # sheetId => name, from workbook.xml
  sheet_xmls     = {}

  Zip::File.open_buffer(StringIO.new(body)) do |zip|
    ss_entry = zip.find_entry("xl/sharedStrings.xml")
    if ss_entry
      listener = SharedStringsListener.new
      REXML::Parsers::StreamParser.new(ss_entry.get_input_stream.read, listener).parse
      shared_strings = listener.strings
    end

    wb_entry = zip.find_entry("xl/workbook.xml")
    if wb_entry
      # workbook.xml is tiny; a light DOM read is fine here for sheet names.
      doc = REXML::Document.new(wb_entry.get_input_stream.read)
      REXML::XPath.each(doc, "//sheet") do |s|
        idx  = s.attributes["sheetId"]
        name = s.attributes["name"]
        sheet_names[idx] = name if idx && name
      end
    end

    zip.each do |entry|
      if entry.name =~ %r{xl/worksheets/sheet(\d+)\.xml}
        sheet_xmls[$1] = entry.get_input_stream.read
      end
    end
  end

  if sheet_xmls.empty?
    warn "Spreadsheet appears to be empty"
    exit 1
  end

  sections = []
  sheet_xmls.keys.sort_by(&:to_i).each do |idx|
    name = sheet_names[idx] || "Sheet#{idx}"

    listener = SheetListener.new(shared_strings)
    REXML::Parsers::StreamParser.new(sheet_xmls[idx], listener).parse
    rows = listener.rows

    next if rows.empty?
    sections << "### #{name}\n\n#{build_markdown_table(rows)}"
  end

  if sections.empty?
    warn "Spreadsheet appears to be empty"
    exit 1
  end

  print sections.join("\n\n")
  exit 0
rescue => e
  warn "Failed to parse XLSX: #{e.message}"
  warn "Tip: ensure rubyzip is installed: gem install rubyzip"
  exit 1
end
