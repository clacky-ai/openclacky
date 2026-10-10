# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "visualize default skill" do
  let(:skill_dir) do
    File.expand_path("../../../lib/clacky/default_skills/visualize", __dir__)
  end
  let(:skill) { Clacky::Skill.new(skill_dir) }

  it "uses the Codex routing description without exceeding the prompt limit" do
    expect(skill.description).to eq(
      "Create visualizations and interactive tools directly in conversation. " \
      "Proactively use to show how something works; explore 'what happens when', " \
      "'what changes', or 'help me understand'; compare or inspect; create " \
      "simulations, maps, charts, graphs, and mockups."
    )
    expect(skill.name_zh).to eq("可视化交互")
    expect(skill.description_zh).to eq(
      "直接在对话中创建可视化和交互工具，用于演示原理、探索变化、比较检查，以及制作模拟、地图、图表和原型。"
    )
    expect(skill.description.length).to be <= Clacky::Skill::DESCRIPTION_MAX_CHARS
    expect(skill.context_description).to eq(skill.description)
  end

  it "publishes HTML as a content reference and removes its temporary source" do
    Dir.mktmpdir("visualize_skill_spec") do |home|
      input = File.join(home, "visualization.html")
      File.write(input, "<button>Go</button>")

      stdout, stderr, status = Open3.capture3(
        { "HOME" => home },
        RbConfig.ruby,
        File.join(skill_dir, "publish.rb"),
        "--title", "Demo",
        "--height", "999",
        "--delete-source",
        input
      )

      expect(status).to be_success, stderr
      match = stdout.match(/\Avisualize(\{.*\})\s*\z/)
      expect(match).not_to be_nil
      payload = JSON.parse(match[1])
      expect(payload).to include("title" => "Demo", "height" => 720)
      expect(payload["artifact_id"]).to match(/\A[0-9a-f]{64}\z/)
      expect(File).not_to exist(input)
      expect(File).to exist(File.join(home, ".clacky", "artifacts", "#{payload["artifact_id"]}.html"))
    end
  end
end
