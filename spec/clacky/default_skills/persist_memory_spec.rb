# frozen_string_literal: true

RSpec.describe "persist-memory default skill" do
  let(:skill_dir) do
    File.expand_path("../../../lib/clacky/default_skills/persist-memory", __dir__)
  end

  let(:content) do
    Clacky::Skill.new(skill_dir).process_content(template_context: { "memories_meta" => "(none)" })
  end

  it "limits description to one short line describing scope, not history" do
    expect(content).to include("### The `description` field")
    expect(content).to match(/at most 80 characters/i)
    expect(content).to match(/No dates, version history/i)
  end

  it "requires Why / How to apply for rules and absolute dates" do
    expect(content).to include("**Why**")
    expect(content).to include("**How to apply**")
    expect(content).to match(/absolute dates/i)
  end

  it "keeps current state instead of appending a timeline" do
    expect(content).to match(/Keep the current state, not a timeline/i)
  end

  it "leaves out implementation details unless the user's own words request them" do
    expect(content).to match(/Leave out code paths/i)
    expect(content).to match(/\*\*user's own words\*\*/)
    expect(content).to match(/details the calling agent added on its own do not count/i)
  end

  it "forbids adding facts the task did not state" do
    expect(content).to match(/Record only facts stated in the task/i)
  end

  it "keeps content rules in force even when told to persist" do
    expect(content).to match(/content rules in Guidelines still decide which details/i)
  end
end

RSpec.describe "base prompt memory instructions" do
  let(:base) { File.read(File.expand_path("../../../lib/clacky/prompts/base.md", __dir__)) }

  it "tells the main agent not to pass implementation details to persist-memory" do
    expect(base).to match(/Pass only the decision, its reason, and the user's own words/)
  end
end
