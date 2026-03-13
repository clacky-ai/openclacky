# frozen_string_literal: true

require "tmpdir"
require "tempfile"

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Processes file attachments downloaded from Feishu messages.
        # Returns file content or path info to be injected into the agent prompt.
        module FileProcessor
          # Text formats: read content and embed directly in the prompt
          TEXT_FORMATS = %w[txt md json html csv].freeze
          # Binary formats parsed directly
          TOOL_FORMATS = %w[pdf docx doc xlsx xls].freeze

          MAX_TEXT_BYTES = 200 * 1024  # 200KB
          MAX_FILE_BYTES = 50 * 1024 * 1024  # 50MB

          # Process a downloaded file and return a text snippet for the prompt.
          # @param body [String] Raw file bytes
          # @param file_name [String] Original file name (used to detect format)
          # @return [String] Text to inject into the prompt
          def self.process(body, file_name)
            ext = File.extname(file_name).downcase.delete_prefix(".")

            unless TEXT_FORMATS.include?(ext) || TOOL_FORMATS.include?(ext)
              return "[Attachment: #{file_name}]\n⚠️ Unsupported format .#{ext}."
            end

            if body.bytesize > MAX_FILE_BYTES
              return "[Attachment: #{file_name}]\n⚠️ File too large (#{body.bytesize / 1024 / 1024}MB), max #{MAX_FILE_BYTES / 1024 / 1024}MB."
            end

            case ext
            when *TEXT_FORMATS
              embed_text_content(body, file_name)
            when "pdf"
              save_and_reference(body, file_name, "PDF")
            when "docx", "doc"
              extract_docx(body, file_name)
            when "xlsx", "xls"
              extract_xlsx(body, file_name)
            end
          end

          # --- private helpers ---

          def self.embed_text_content(body, file_name)
            text = body.force_encoding("UTF-8")
            text = text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless text.valid_encoding?

            if text.bytesize > MAX_TEXT_BYTES
              text = text.byteslice(0, MAX_TEXT_BYTES) + "\n... [truncated]"
            end

            "[Attachment: #{file_name}]\n```\n#{text.strip}\n```"
          end

          def self.save_and_reference(body, file_name, type_label)
            tmp = Tempfile.new(["feishu_file_", ".#{File.extname(file_name).delete_prefix(".")}"])
            tmp.binmode
            tmp.write(body)
            tmp.flush
            tmp.close
            # Don't unlink — agent needs to read it; GC will clean up eventually
            ObjectSpace.define_finalizer(tmp) { File.unlink(tmp.path) rescue nil }
            "[#{type_label} attached: #{file_name} — file path: #{tmp.path}]"
          end

          def self.extract_docx(body, file_name)
            require "zip"
            require "rexml/document"

            text_parts = []

            Zip::File.open_buffer(StringIO.new(body)) do |zip|
              entry = zip.find_entry("word/document.xml")
              unless entry
                return "[Attachment: #{file_name}]\n⚠️ Could not extract content (possibly encrypted)."
              end

              doc = REXML::Document.new(entry.get_input_stream.read)
              REXML::XPath.each(doc, "//w:p") do |para|
                texts = REXML::XPath.match(para, ".//w:t").map(&:text).compact.join
                text_parts << texts unless texts.strip.empty?
              end
            end

            if text_parts.empty?
              return "[Attachment: #{file_name}]\n⚠️ Could not extract content (possibly encrypted)."
            end

            content = text_parts.join("\n")
            if content.bytesize > MAX_TEXT_BYTES
              content = content.byteslice(0, MAX_TEXT_BYTES) + "\n... [truncated]"
            end
            "[Attachment: #{file_name}]\n```\n#{content.strip}\n```"
          rescue => e
            "[Attachment: #{file_name}]\n⚠️ Failed to parse: #{e.message}"
          end

          def self.extract_xlsx(body, file_name)
            require "zip"
            require "rexml/document"

            shared_strings = []
            sheets = {}

            Zip::File.open_buffer(StringIO.new(body)) do |zip|
              ss_entry = zip.find_entry("xl/sharedStrings.xml")
              if ss_entry
                doc = REXML::Document.new(ss_entry.get_input_stream.read)
                REXML::XPath.each(doc, "//si") do |si|
                  shared_strings << REXML::XPath.match(si, ".//t").map(&:text).compact.join
                end
              end

              zip.each do |entry|
                if entry.name =~ %r{xl/worksheets/sheet(\d+)\.xml}
                  sheets[$1.to_i] = entry.get_input_stream.read
                end
              end
            end

            rows_text = []
            sheets.keys.sort.each do |sheet_num|
              doc = REXML::Document.new(sheets[sheet_num])
              REXML::XPath.each(doc, "//row") do |row|
                cells = REXML::XPath.match(row, ".//c").map do |c|
                  t_attr = c.attributes["t"]
                  v = REXML::XPath.first(c, "v")&.text
                  next "" unless v
                  t_attr == "s" ? (shared_strings[v.to_i] || "") : v
                end
                rows_text << cells.join("\t") unless cells.all?(&:empty?)
              end
            end

            if rows_text.empty?
              return "[Attachment: #{file_name}]\n⚠️ Spreadsheet is empty."
            end

            content = rows_text.join("\n")
            if content.bytesize > MAX_TEXT_BYTES
              content = content.byteslice(0, MAX_TEXT_BYTES) + "\n... [truncated]"
            end
            "[Attachment: #{file_name}]\n```\n#{content.strip}\n```"
          rescue => e
            "[Attachment: #{file_name}]\n⚠️ Failed to parse: #{e.message}"
          end

          private_class_method :embed_text_content, :save_and_reference, :extract_docx, :extract_xlsx
        end
      end
    end
  end
end
