# frozen_string_literal: true

module Clacky
  class Agent
    # Read-only navigation: locations at startup, bounded previews on demand.
    module HistoryNavigation
      NAVIGATION_PREVIEW_LENGTH = 400
      NAVIGATION_PREVIEW_BATCH_LIMIT = 30

      def history_navigation
        sources = navigation_sources
        manifest = sources.map do |source|
          entry = { key: source[:key], version: source[:version], count: navigation_source_count(source),
                    volatile: !!source[:rounds] || source[:continuation].to_a.any? }
          entry[:identities] = source[:rounds].map { |round| round[:user_msg].values_at(:created_at, :task_id) } if source[:rounds]
          entry
        end
        { sources: manifest, total: manifest.sum { |source| source[:count] } }
      end

      def history_navigation_preview(id:)
        history_navigation_previews(ids: [id]).fetch(0)
      end

      def history_navigation_previews(ids:)
        ids = Array(ids)
        if ids.length > NAVIGATION_PREVIEW_BATCH_LIMIT
          raise ArgumentError, "Too many history locations"
        end

        sources = navigation_sources
        ids.map do |id|
          source_index, offset = navigation_position(sources, id)
          unless offset && offset < navigation_source_count(sources[source_index])
            raise ArgumentError, "History location is no longer available"
          end
          navigation_entry(navigation_source_rounds(sources, source_index, offset: offset, limit: 1).fetch(0))
        end
      end

      def replay_history_window(ui, limit: 30, around: nil, before_id: nil, after_id: nil)
        sources = navigation_sources
        anchor = around || before_id || after_id
        source_index, offset = anchor ? navigation_position(sources, anchor) : [sources.length - 1, nil]
        count = navigation_source_count(sources[source_index])
        offset ||= count
        raise ArgumentError, "History location is no longer available" if anchor && offset >= count

        # Around starts at the requested round; before/after are exclusive.
        forward = !!(around || after_id)
        offset += 1 if after_id
        page = []
        index = source_index
        while index.between?(0, sources.length - 1) && page.length < limit
          count = navigation_source_count(sources[index])
          if forward
            first = index == source_index ? offset : 0
            page.concat(navigation_source_rounds(sources, index, offset: first, limit: limit - page.length))
            index += 1
          else
            last = index == source_index ? offset : count
            first = [last - (limit - page.length), 0].max
            page = navigation_source_rounds(sources, index, offset: first, limit: last - first) + page
            index -= 1
          end
        end

        if page.empty? && !anchor
          @history.to_a.each do |message|
            next if message[:role].to_s == "system" || message[:system_injected]
            _replay_single_message(message, ui)
          end
        else
          replay_rounds(ui, page)
        end
        first = page.first&.dig(:navigation_id)
        last = page.last&.dig(:navigation_id)
        first_pos = first && navigation_position(sources, first)
        last_pos = last && navigation_position(sources, last)
        has_before = first_pos && (first_pos[1].positive? || first_pos[0].positive?)
        has_after = last_pos && (last_pos[1] < navigation_source_count(sources[last_pos[0]]) - 1 ||
          ((last_pos[0] + 1)...sources.length).any? { |i| navigation_source_count(sources[i]).positive? })
        {
          has_more: !!has_before, has_after: !!has_after,
          before_cursor: first, after_cursor: last,
          round_ids: page.map { |round| round[:navigation_id] }
        }
      end

      private def real_history_user?(msg)
        return false unless msg[:role].to_s == "user" && !msg[:system_injected]

        content = msg[:content]
        if content.is_a?(String)
          !content.start_with?("[SYSTEM]")
        elsif content.is_a?(Array)
          content.any? { |block| block.is_a?(Hash) && %w[text image image_url].include?((block[:type] || block["type"]).to_s) }
        else
          false
        end
      end

      private def navigation_sources
        messages = @history.to_a
        rounds = []
        leading = []
        chunks = []
        messages.each do |msg|
          if real_history_user?(msg)
            rounds << { user_msg: msg, events: [], editable: true }
          elsif msg[:compressed_summary]
            paths = if msg[:chunk_path].to_s.empty?
              session_manager.chunks_for_current(@session_id, @created_at).map { |chunk| chunk[:path] }
            else
              sibling_chunks_of(msg[:chunk_path])
            end
            chunks.concat(paths)
          elsif rounds.empty?
            leading << msg unless msg[:role].to_s == "system" || msg[:system_injected]
          else
            rounds.last[:events] << msg
          end
        end
        sources = []
        visited = Set.new
        top_level = chunks.map { |path| File.basename(path) }.to_set
        append_source = lambda do |path|
          path = File.join(Clacky::SessionManager::SESSIONS_DIR, File.basename(path)) unless File.exist?(path)
          path = File.expand_path(path)
          next unless visited.add?(path)

          index = chunk_navigation_index(path)
          # Legacy nested references precede this source's own rounds. Sibling
          # chunks already enumerated above must not be counted twice.
          index[:nested].reverse_each do |nested|
            append_source.call(nested) unless top_level.include?(File.basename(nested))
          end
          sources << { key: File.basename(path), path: path, version: index[:version], index: index }
        end
        chunks.uniq.each { |path| append_source.call(path) }
        @chunk_index_mutex&.synchronize { @chunk_indexes&.delete_if { |path, _| !visited.include?(path) } }
        last_archive = sources.reverse_each.find { |source| navigation_source_count(source).positive? }
        last_archive[:continuation] = leading if last_archive
        version = rounds.map { |round| round[:user_msg].values_at(:created_at, :task_id) }.hash.to_s
        sources << { key: "live", rounds: rounds, version: version }
        sources
      end

      private def navigation_source_count(source)
        source[:rounds] ? source[:rounds].length : source[:index][:rounds].length
      end

      private def navigation_id(source, offset)
        identity = source[:rounds] && offset && source[:rounds][offset]&.dig(:user_msg)&.values_at(:created_at, :task_id)
        JSON.generate([source[:key], offset, source[:version], identity])
      end

      private def navigation_position(sources, id)
        key, offset, version, identity = JSON.parse(id)
        index = sources.index { |source| source[:key] == key }
        if index && key == "live" && version != sources[index][:version] && identity.is_a?(Array) && identity.any?
          matches = sources[index][:rounds].each_index.select do |i|
            sources[index][:rounds][i][:user_msg].values_at(:created_at, :task_id) == identity
          end
          if matches.one?
            offset = matches.first
            version = sources[index][:version]
          end
        end
        unless index && sources[index][:version] == version && (offset.nil? || (offset.is_a?(Integer) && offset >= 0))
          raise ArgumentError, "History location is no longer available"
        end
        [index, offset]
      rescue JSON::ParserError, TypeError
        raise ArgumentError, "Invalid history location"
      end

      private def navigation_source_rounds(sources, index, offset: 0, limit: nil)
        source = sources.fetch(index)
        count = navigation_source_count(source)
        length = [limit || count, count - offset].min
        return [] unless length.positive?

        siblings = sources.filter_map { |entry| entry[:key] if entry[:path] && entry != source }.to_set
        rounds = if source[:rounds]
          source[:rounds].slice(offset, length)
        else
          ranges = source[:index][:rounds]
          first = ranges[offset]
          last = ranges[offset + length - 1]
          range = { start: first[:start], length: last[:start] + last[:length] - first[:start] }
          result = parse_chunk_md_to_rounds(source[:path], excluded_paths: siblings, byte_range: range,
            index: source[:index], round_offset: offset)
          unless chunk_file_version(source[:path]) == source[:version] && result.length == length
            raise ArgumentError, "History changed while reading"
          end
          result
        end
        if rounds.any? && offset + length == count && source[:continuation]
          rounds.last[:events].concat(source[:continuation])
        end
        rounds.each { |round| round[:events].reject! { |event| event[:compressed_summary] } }
        rounds.each_with_index do |round, position|
          round[:navigation_id] = navigation_id(source, offset + position)
        end
        rounds
      end

      private def navigation_entry(round)
        msg = round[:user_msg]
        user = navigation_preview(msg[:display_text] || extract_text_from_content(msg[:content]))
        if user.empty?
          names = Array(msg[:display_files]).map { |file| file[:name] || file["name"] }
          Array(msg[:content]).each do |block|
            next unless block.is_a?(Hash) && %w[image image_url].include?((block[:type] || block["type"]).to_s)
            names << (block[:image_name] || block["image_name"] || "image")
          end
          user = navigation_preview(names.compact.join(", "))
        end
        # A final reply is the last main-agent response, with no pending tool
        # work. Earlier narration, reasoning and nested subagent transcripts
        # must never be substituted for a missing final response.
        last = round[:events].reverse.find do |event|
          !event[:system_injected] && !event[:compressed_summary] &&
            %w[assistant tool].include?(event[:role].to_s)
        end
        final = last && last[:role].to_s == "assistant" && !last[:interim] && Array(last[:tool_calls]).empty?
        answer = final ? navigation_preview(extract_text_from_content(last[:content])) : ""
        { id: round[:navigation_id], created_at: msg[:created_at], archived: round[:editable] == false,
          user: user, assistant: answer }
      end

      private def navigation_preview(text)
        text.to_s.gsub(/<think>.*?(?:<\/think>|\z)/m, "")
          .strip[0, NAVIGATION_PREVIEW_LENGTH]
      end
    end
  end
end
