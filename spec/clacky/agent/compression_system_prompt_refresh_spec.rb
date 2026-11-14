# frozen_string_literal: true

RSpec.describe "Compression refreshes system prompt" do
  let(:directory) { Dir.mktmpdir }
  let(:client) { instance_double(Clacky::Client) }
  let(:config) { Clacky::AgentConfig.new(model: "gpt-3.5-turbo", permission_mode: :auto_approve) }
  let(:agent) do
    Clacky::Agent.new(client, config, working_dir: directory, ui: nil,
                     profile: "general", session_id: Clacky::SessionManager.generate_id, source: :manual)
  end
  let(:recent) { { role: "user", content: "Continue our task" } }

  before do
    stub_const("Clacky::AgentProfile::USER_AGENTS_DIR", directory)
    stub_const("Clacky::SessionManager::SESSIONS_DIR", File.join(directory, "sessions"))
    File.write(File.join(directory, "USER.md"), "Old user preference")
    File.write(File.join(directory, "SOUL.md"), "Old assistant personality")
    agent.history.append(role: "system", content: agent.build_system_prompt)
    agent.history.append(role: "user", content: "Earlier task")
    agent.history.append(recent)
  end

  after { FileUtils.rm_rf(directory) }

  def compress(force_new_chunk: true)
    context = {
      recent_messages: [recent], original_token_count: 50_000,
      original_message_count: agent.history.size, compression_level: 1,
      force_new_chunk: force_new_chunk
    }
    agent.history.append(role: "user", content: "Compress history", system_injected: true)
    agent.handle_compression_response({ content: "<summary>Task in progress</summary>" }, context)
  end

  [true, false].each do |force_new_chunk|
    it "reloads profiles across repeated #{force_new_chunk ? 'active' : 'idle'} compressions" do
      2.times do |index|
        File.write(File.join(directory, "USER.md"), "New user preference #{index}")
        File.write(File.join(directory, "SOUL.md"), "New assistant personality #{index}")
        # Updating files does not mutate the prompt before compression.
        expect(agent.history.to_a.first[:content]).not_to include("New user preference #{index}")

        compress(force_new_chunk: force_new_chunk)

        systems = agent.history.to_a.select { |message| message[:role] == "system" }
        expect(systems.size).to eq(1)
        expect(systems.first[:content]).to include("New user preference #{index}", "New assistant personality #{index}")
        expect(systems.first[:content]).not_to include("Old user preference", "Old assistant personality")
        expect(agent.history.to_a.last).to include(recent)
        expect(agent.history.to_a.any? { |message| message[:compressed_summary] }).to be(true)
        expect(agent.instance_variable_get(:@previous_total_tokens)).to eq(agent.history.estimate_tokens)
      end
    end
  end

  it "uses the default profile after a profile file is deleted" do
    File.delete(File.join(directory, "USER.md"))
    compress
    expect(agent.history.to_a.first[:content]).to include(Clacky::AgentProfile::DEFAULT_USER)
    expect(agent.history.to_a.first[:content]).not_to include("Old user preference")
  end

  it "rejects a refreshed prompt that cannot fit without replacing live history" do
    original = agent.history.to_a
    config.compression_threshold = 1_000
    allow(agent).to receive(:build_system_prompt).and_return("large prompt " * 10_000)

    expect { compress }.to raise_error(/still exceeds compression thresholds/)
    expect(agent.history.to_a[0...-1]).to eq(original)
    expect(agent.instance_variable_get(:@compressed_summaries)).to be_empty
  end

  it "leaves live history untouched when rebuilding the prompt fails" do
    original = agent.history.to_a
    allow(agent).to receive(:build_system_prompt).and_raise(IOError, "Cannot read profile")

    expect { compress }.to raise_error(IOError, "Cannot read profile")
    expect(agent.history.to_a[0...-1]).to eq(original)
  end
end
