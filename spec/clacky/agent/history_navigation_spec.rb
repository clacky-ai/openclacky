# frozen_string_literal: true

require "clacky/server/http_server"

RSpec.describe Clacky::Agent::HistoryNavigation do
  let(:directory) { Dir.mktmpdir("navigation-spec") }
  let(:events) { [] }
  let(:collector) { Clacky::Server::HistoryCollector.new("navigation-test", events) }

  after { FileUtils.rm_rf(directory) }

  def agent_for(messages)
    Class.new do
      include Clacky::Agent::SessionSerializer
      attr_reader :history
      def initialize(messages)
        @history = Clacky::MessageHistory.new(messages)
      end
    end.new(messages)
  end

  def user(text, time = 1)
    { role: "user", content: text, created_at: time }
  end

  def assistant(text, **options)
    { role: "assistant", content: text }.merge(options)
  end

  def chunk(number, body)
    path = File.join(directory, "session-chunk-#{number}.md")
    File.write(path, "---\narchived_at: 2026-03-01T10:00:00Z\n---\n#{body}")
    path
  end

  def archived_agent(path, tail = [])
    agent_for([assistant("summary", compressed_summary: true, chunk_path: path)] + tail)
  end

  def all_entries(agent)
    agent.history_navigation[:sources].flat_map do |source|
      Array.new(source[:count]) do |offset|
        id = JSON.generate([source[:key], offset, source[:version], source[:identities]&.[](offset)])
        agent.history_navigation_preview(id: id)
      end
    end
  end

  it "indexes user turns and only their final main-agent answer" do
    agent = agent_for([
      user("First"), assistant("Investigating", tool_calls: [{ name: "read" }]),
      { role: "tool", content: "private output", subagent_transcript: [{ role: "assistant", content: "subagent answer" }] },
      assistant("<think>hidden reasoning</think>Final answer"),
      user("Second", 2), assistant("Working", tool_calls: [{ name: "ask_user" }]),
      user("synthetic", 3).merge(system_injected: true)
    ])
    expect(all_entries(agent).map { |entry| [entry[:user], entry[:assistant]] }).to eq([
      ["First", "Final answer"], ["Second", ""]
    ])
  end

  it "does not mistake interrupted tool work or reasoning-only output for a final answer" do
    agent = agent_for([user("run"), assistant("Earlier answer"), assistant("", tool_calls: [{ name: "read" }]),
      { role: "tool", content: "interrupted" }])
    expect(all_entries(agent).first[:assistant]).to eq("")
    agent.history.append(assistant("<think>reasoning only</think>"))
    expect(all_entries(agent).first[:assistant]).to eq("")
  end

  it "uses attachment names for image-only turns without encoding image data" do
    agent = agent_for([user([{ type: "image_url", image_name: "screenshot.png", image_url: { url: "data:image/png;base64,PRIVATE" } }])])
    entry = all_entries(agent).first
    expect(entry[:user]).to eq("screenshot.png")
    expect(JSON.generate(entry)).not_to include("PRIVATE")
  end

  it "bounds previews and excludes tool outputs from the index" do
    agent = agent_for([user("x" * 1000), assistant("y" * 1000), { role: "tool", content: "secret" * 10000 }])
    entry = all_entries(agent).first
    expect(entry[:user].length).to eq(400)
    expect(JSON.generate(entry).length).to be < 1000
  end

  it "preserves Markdown structure for compact client rendering without exposing reasoning" do
    markdown = "# Result\n\n**Fixed** `List<T>`\n\n- First\n- Second\n\n```ruby\nputs '<tag>'\n```"
    agent = agent_for([user("**Review**\n\n`main`"), assistant("<think>private reasoning</think>\n#{markdown}")])
    entry = all_entries(agent).first
    expect(entry[:user]).to eq("**Review**\n\n`main`")
    expect(entry[:assistant]).to eq(markdown)
    expect(entry[:assistant]).not_to include("private reasoning")
  end

  it "counts all archived and live turns without parsing bodies or producing previews" do
    path = chunk(1, "## User\nOld\n## Assistant\nArchived answer\n")
    agent = archived_agent(path, [user("Live", 20), assistant("Live answer")])
    expect(agent).not_to receive(:parse_chunk_md_to_rounds)
    expect(agent).not_to receive(:navigation_entry)
    expect(agent).not_to receive(:parse_tool_calls_line)
    manifest = agent.history_navigation
    expect(manifest[:total]).to eq(2)
    expect(manifest[:sources].map { |source| source[:count] }).to eq([1, 1])
    expect(JSON.generate(manifest)).not_to include("Archived answer", "Live answer")
  end

  it "does not use colliding archived timestamps as navigation identities" do
    chunk(1, "## User\nFirst\n## Assistant\nOne\n")
    path = chunk(2, "## User\nSecond\n## Assistant\nTwo\n")
    agent = archived_agent(path)
    entries = all_entries(agent)
    expect(entries.map { |entry| entry[:created_at] }.uniq.length).to eq(1)
    expect(entries.map { |entry| entry[:id] }.uniq.length).to eq(2)
    result = agent.replay_history_window(collector, around: entries.last[:id], limit: 1)
    expect(events.first[:content]).to eq("Second")
    expect(result).to include(has_more: true, has_after: false)
    expect(events.first[:editable]).to eq(false)
  end

  it "supports exclusive before and after windows across chunk/live boundaries" do
    path = chunk(1, "## User\nOld\n## Assistant\nArchived answer\n")
    agent = archived_agent(path, [user("Middle", 20), assistant("Two"), user("Newest", 30)])
    entries = all_entries(agent)
    before = agent.replay_history_window(collector, before_id: entries[1][:id], limit: 1)
    expect(events.first[:content]).to eq("Old")
    expect(before).to include(has_more: false, has_after: true)
    events.clear
    after = agent.replay_history_window(collector, after_id: entries[0][:id], limit: 1)
    expect(events.first[:content]).to eq("Middle")
    expect(after).to include(has_more: true, has_after: true)
  end

  it "preserves the live continuation of an archived user turn" do
    path = chunk(1, "## User\nOld\n## Assistant\nReading\n_Tool calls: read_\n")
    agent = archived_agent(path, [assistant("Final continued answer")])
    entries = all_entries(agent)
    expect(entries.first[:assistant]).to eq("Final continued answer")
    agent.replay_history_window(collector, around: entries.first[:id])
    expect(events.count { |event| event[:content] == "Final continued answer" }).to eq(1)
  end

  it "attaches live continuation to the last user turn when newer archives have no user turns" do
    original = chunk(1, "## User\nQuestion\n## Assistant\nEarlier answer\n")
    path = chunk(2, "## Assistant\nSummary-only archive\n")
    agent = archived_agent(path, [assistant("Final continued answer")])
    manifest = agent.history_navigation
    expect(manifest[:total]).to eq(1)
    expect(manifest[:sources].find { |source| source[:key] == File.basename(original) }[:volatile]).to eq(true)
    entry = all_entries(agent).first
    expect(entry[:assistant]).to eq("Final continued answer")
    result = agent.replay_history_window(collector, around: entry[:id])
    expect(result).to include(has_more: false, has_after: false)
    expect(events.count { |event| event[:content] == "Final continued answer" }).to eq(1)
  end

  it "keeps archived tool narration interim during both preview and replay" do
    path = chunk(1, "## User\nRun\n## Assistant\nLet me check\n_Tool calls: read_\n")
    agent = archived_agent(path)
    entry = all_entries(agent).first
    expect(entry[:assistant]).to eq("")
    agent.replay_history_window(collector, around: entry[:id])
    expect(events.find { |event| event[:type] == "assistant_message" }[:interim]).to eq(true)
  end

  it "rejects stale live locators after editing instead of jumping to another turn" do
    agent = agent_for([user("First", 10), user("Second", 20)])
    id = all_entries(agent).last[:id]
    agent.history.replace_all([user("Different", 30), user("Other", 40)])
    expect { agent.replay_history_window(collector, around: id) }.to raise_error(ArgumentError)
    expect(events).to be_empty
  end

  it "rejects malformed and out-of-range locators" do
    agent = agent_for([user("First")])
    expect { agent.replay_history_window(collector, around: "not-json") }.to raise_error(ArgumentError)
    id = JSON.parse(all_entries(agent).first[:id])
    id[1] = 500
    expect { agent.replay_history_window(collector, around: JSON.generate(id)) }.to raise_error(ArgumentError)
  end

  it "keeps an existing live target addressable when a newer user turn arrives" do
    agent = agent_for([user("First", 10), user("Second", 20)])
    id = all_entries(agent).last[:id]
    agent.history.append(user("Third", 30))
    agent.replay_history_window(collector, around: id, limit: 1)
    expect(events.first[:content]).to eq("Second")
  end

  it "does not duplicate sibling chunks also referenced by a nested summary" do
    chunk(1, "## User\nOriginal\n## Assistant\nOriginal answer\n")
    path = chunk(2, "## Assistant [Compressed Summary — original conversation at: session-chunk-1.md]\nSummary\n## User\nNewer\n")
    agent = archived_agent(path)
    expect(all_entries(agent).map { |entry| entry[:user] }).to eq(["Original", "Newer"])
    agent.replay_history_window(collector)
    expect(events.select { |event| event[:type] == "history_user_message" }.size).to eq(2)
  end

  it "uses current live continuation summaries even after an earlier index was cached" do
    path = chunk(1, "## User\nQuestion\n## Assistant\nWorking\n_Tool calls: read_\n")
    agent = archived_agent(path, [assistant("Still working", tool_calls: [{ name: "read" }])])
    expect(all_entries(agent).first[:assistant]).to eq("")
    expect(agent.history_navigation[:sources].find { |source| source[:key] == File.basename(path) }[:volatile]).to eq(true)
    agent.history.append(assistant("Finished"))
    expect(all_entries(agent).first[:assistant]).to eq("Finished")
  end

  it "returns the complete turn count and identities without preview pagination" do
    agent = agent_for((1..450).map { |i| user("Question #{i}", i) })
    expect(agent.history_navigation[:total]).to eq(450)
    expect(all_entries(agent).map { |entry| entry[:user] }).to eq((1..450).map { |i| "Question #{i}" })
  end

  it "reuses byte indexes without caching full message bodies" do
    path = chunk(1, "## User\nOld\n## Assistant\nOriginal\n")
    agent = archived_agent(path)
    all_entries(agent)
    expect(agent).not_to receive(:scan_chunk_index)
    expect(all_entries(agent).first[:assistant]).to eq("Original")
    expect(JSON.generate(agent.instance_variable_get(:@chunk_indexes))).not_to include("Original")
  end

  it "invalidates a rewritten archive and keeps missing chunks harmless" do
    path = chunk(1, "## User\nOld\n## Assistant\nOriginal\n")
    agent = archived_agent(path)
    original = all_entries(agent).first[:id]
    File.write(path, "## User\nNew\n## Assistant\nChanged answer\n")
    expect(all_entries(agent).first[:assistant]).to eq("Changed answer")
    expect { agent.replay_history_window(collector, around: original) }.to raise_error(ArgumentError)
    File.unlink(path)
    expect(all_entries(agent)).to be_empty
  end

  it "reads only the requested round's bytes even in an archive exceeding 2000 turns" do
    path = chunk(1, (1..2100).map { |i| "## User\nQuestion #{i}\n## Assistant\nAnswer #{i}\n" }.join)
    agent = archived_agent(path)
    source = agent.history_navigation[:sources].first
    expect(source[:count]).to eq(2100)
    id = JSON.generate([source[:key], 1500, source[:version], nil])
    expect(agent).not_to receive(:scan_chunk_index)
    expect(agent).to receive(:parse_chunk_md_to_rounds).with(path, hash_including(
      byte_range: { start: kind_of(Integer), length: be < 100 }, round_offset: 1500
    )).twice.and_call_original
    2.times { expect(agent.history_navigation_preview(id: id)[:assistant]).to eq("Answer 1501") }
  end

  it "matches replay for empty users, attachment-only users, nested archives and UTF-8 offsets" do
    nested = File.join(directory, "legacy.md")
    File.write(nested, "## User\n旧记录\n## Assistant\n旧回复\n")
    path = chunk(1, <<~MD)
      ## Assistant [Compressed Summary — original conversation at: legacy.md]
      Summary
      ## User

      ## User
      _Display files: []_
      ## User [Task 3]
      _Display files: [{"name":"截图.png","type":"image"}]_
      ## Assistant
      图片回复
      ## User
      最后一轮
      ## Assistant
      最终回复
    MD
    agent = archived_agent(path)
    full = agent.send(:parse_chunk_md_to_rounds, path)
    entries = all_entries(agent)
    expect(entries.map { |entry| entry[:assistant] }).to eq(["旧回复", "图片回复", "最终回复"])
    entries.each_with_index do |entry, position|
      events.clear
      agent.replay_history_window(collector, around: entry[:id], limit: 1)
      expect(events.first[:created_at]).to eq(full[position][:user_msg][:created_at])
    end
  end

  it "does not repeatedly scan a session with more than six archives" do
    paths = (1..8).map { |i| chunk(i, "## User\nQuestion #{i}\n## Assistant\nAnswer #{i}\n") }
    agent = archived_agent(paths.last)
    expect(agent.history_navigation[:total]).to eq(8)
    expect(agent).not_to receive(:scan_chunk_index)
    expect(all_entries(agent).size).to eq(8)
  end

  it "rejects a preview if the archive is rewritten during the range read" do
    path = chunk(1, "## User\nQuestion\n## Assistant\nAnswer\n")
    agent = archived_agent(path)
    id = all_entries(agent).first[:id]
    allow(agent).to receive(:parse_chunk_md_to_rounds).and_wrap_original do |original, *args, **kwargs|
      result = original.call(*args, **kwargs)
      File.write(path, "## User\nReplacement\n## Assistant\nNew answer\n")
      result
    end
    expect { agent.history_navigation_preview(id: id) }.to raise_error(ArgumentError, /changed/)
  end
end
