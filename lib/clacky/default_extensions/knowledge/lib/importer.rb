# frozen_string_literal: true

module Clacky
  module Knowledge
    # Turns an uploaded file into an entry: md / txt keep their frontmatter,
    # PDF / Word go through the host's document parsers. `read_file` only
    # converts (single-file upload preview); `import_file` also saves (folder
    # import, where the browser sends the folder's files one by one).
    class Importer
      TEXT_EXTS   = %w[.md .markdown .txt].freeze
      PARSED_EXTS = %w[.pdf .doc .docx .wps].freeze
      MAX_BYTES   = 50 * 1024 * 1024

      class ImportError < StandardError; end
      class UnsupportedError < ImportError; end

      def self.supported?(name)
        (TEXT_EXTS + PARSED_EXTS).include?(File.extname(name.to_s).downcase)
      end

      def initialize(store)
        @store = store
      end

      # Turn one file into entry fields without saving — used by the upload
      # preview. `filename` is the user-facing name (uploads arrive in a temp
      # path). Returns { title:, source:, body:, parsed: }.
      def read_file(path, filename: File.basename(path))
        ext = File.extname(filename).downcase
        raise UnsupportedError, "unsupported file type: #{ext.empty? ? filename : ext}" unless self.class.supported?(filename)
        size = File.size(path)
        raise ImportError, "empty file" if size.zero?
        raise ImportError, "file too large (max 50MB)" if size > MAX_BYTES

        title = File.basename(filename, File.extname(filename))
        if TEXT_EXTS.include?(ext)
          meta, body = @store.parse_markdown(File.read(path, encoding: "UTF-8").scrub(""))
          { title: (meta["title"] || title).to_s, source: meta["source"], body: body, parsed: false }
        else
          { title: title, source: filename, body: parse_document(path), parsed: true }
        end
      end

      # Read and save one file into `folder` (relative to entries/, "" = top
      # level). Returns the entry's relative path.
      def import_file(path, filename: File.basename(path), folder: nil)
        fields = read_file(path, filename: filename)
        @store.save(folder: folder, **fields.slice(:title, :source, :body))
      end

      private def parse_document(path)
        Clacky::Utils::ParserManager.setup!
        result = Clacky::Utils::ParserManager.parse(path)
        raise ImportError, "parse failed: #{result[:error]}" unless result[:success]
        text = result[:text].to_s.gsub(/^--- Page \d+ ---$\n*/, "").gsub(/\n{3,}/, "\n\n").strip
        raise ImportError, "no text found (scanned document?)" if text.empty?
        text
      end
    end
  end
end
