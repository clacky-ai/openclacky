# frozen_string_literal: true

module Clacky
  class Agent
    # Byte ranges only: no message bodies, tool outputs or persistent sidecars.
    module ChunkIndex
      private def chunk_section_header(line, directory)
        if (match = line.match(/\A## Assistant \[Compressed Summary — original conversation at: (.+)\]/))
          { role: "assistant", nested_chunk: File.join(directory, match[1]) }
        elsif (match = line.match(/\A## (User|Assistant)(?: \[Task ([1-9]\d*)\])?\z/))
          { role: match[1].downcase, task_id: match[2]&.to_i }
        elsif line.start_with?("### Tool Result:")
          { role: "tool" }
        end
      end

      private def chunk_file_version(path)
        stat = File.stat(path)
        [stat.size, stat.mtime.to_f, stat.ctime.to_f].join(":")
      rescue Errno::ENOENT
        "missing"
      end

      private def chunk_navigation_index(path)
        version = chunk_file_version(path)
        @chunk_index_mutex ||= Mutex.new
        @chunk_index_mutex.synchronize do
          @chunk_indexes ||= {}
          cached = @chunk_indexes[path]
          return cached if cached && cached[:version] == version

          index = version == "missing" ? { rounds: [], nested: [], section_count: 0 } : scan_chunk_index(path)
          raise ArgumentError, "History changed while indexing" unless chunk_file_version(path) == version

          @chunk_indexes[path] = index.merge(version: version)
        end
      end

      private def scan_chunk_index(path)
        rounds = []
        nested = []
        section_count = 0
        user_start = nil
        archived_at = nil
        front_matter = false
        directory = File.dirname(path)
        position = 0
        File.open(path, "rb") do |file|
          while (line = file.gets)
            start = position
            position += line.bytesize
            text = line.force_encoding(Encoding::UTF_8).scrub.chomp
            if start.zero? && text == "---"
              front_matter = true
            elsif front_matter
              front_matter = false if text == "---"
              archived_at = (Time.parse(text.split(":", 2).last.strip) rescue nil) if text.start_with?("archived_at:")
            end
            header = chunk_section_header(text, directory)
            if header
              section_count += 1
              nested << header[:nested_chunk] if header[:nested_chunk]
              user_start = header[:role] == "user" ? start : nil
            elsif user_start && !text.strip.empty?
              # Match replay's empty/metadata-only user handling without
              # retaining the rest of the user message or any assistant text.
              visible, events = extract_ext_events_from_text(text)
              visible, files = extract_display_files_from_text(visible)
              next if visible.empty? && events.empty? && files.empty?

              rounds.last[:length] = user_start - rounds.last[:start] if rounds.any?
              rounds << { start: user_start }
              user_start = nil
            end
          end
          rounds.last[:length] = position - rounds.last[:start] if rounds.any?
        end
        { rounds: rounds, nested: nested, section_count: section_count,
          base_time: (archived_at || File.mtime(path)).to_f }
      end
    end
  end
end
