# frozen_string_literal: true

RSpec.describe "reference chips across compression" do
  let(:writer) do
    Class.new do
      include Clacky::Agent::MessageCompressorHelper
      public :render_message_sections
    end.new
  end

  let(:reader) do
    Class.new do
      include Clacky::Agent::SessionSerializer
      public :extract_display_references_from_text
    end.new
  end

  let(:quote_chip) { { type: "quote", text: "麻烦再发一次附件", label: "上一条回复" } }
  let(:file_chip) { { type: "file", name: "app.rb", path: "/tmp/app.rb" } }

  def archived_sections(display_references, content: "")
    writer.render_message_sections([
      { role: "user", content: content, display_references: display_references }
    ]).join("\n")
  end

  it "archives reference chips with their provenance but not the model-facing context" do
    md = archived_sections([quote_chip.merge(context: "[Quoted excerpt]\n麻烦再发一次附件")])

    expect(md).to include("_Display references: [")
    expect(md).to include('"type":"quote"')
    expect(md).to include("麻烦再发一次附件")
    expect(md).to include("上一条回复")
    expect(md).not_to include("Quoted excerpt")
  end

  it "omits the marker when a user message carries no references" do
    expect(archived_sections([])).not_to include("_Display references:")
  end

  it "restores chips and strips the archive marker from the replayed text" do
    text, references = reader.extract_display_references_from_text(
      "看这个\n_Display references: #{[quote_chip, file_chip].to_json}_"
    )

    expect(text).to eq("看这个")
    expect(references).to eq([quote_chip, file_chip])
  end

  it "leaves text untouched when no marker is present" do
    text, references = reader.extract_display_references_from_text("只有正文")

    expect(text).to eq("只有正文")
    expect(references).to eq([])
  end

  it "survives a write/read round trip" do
    text, references = reader.extract_display_references_from_text(
      archived_sections([quote_chip, file_chip], content: "看这个")
    )

    expect(text).to end_with("看这个")
    expect(references).to eq([quote_chip, file_chip])
  end
end
