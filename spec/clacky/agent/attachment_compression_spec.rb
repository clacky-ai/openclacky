# frozen_string_literal: true

RSpec.describe "attachment metadata across compression" do
  let(:writer) do
    Class.new do
      include Clacky::Agent::MessageCompressorHelper
      public :render_message_sections
    end.new
  end

  let(:reader) do
    Class.new do
      include Clacky::Agent::SessionSerializer
      public :extract_display_files_from_text
    end.new
  end

  it "archives only attachment name and type" do
    md = writer.render_message_sections([
      {
        role: "user",
        content: "",
        display_files: [{
          name: "data.csv",
          type: "csv",
          path: "/tmp/private/data.csv",
          preview_path: "/tmp/private/preview.md",
          size_bytes: 12_345,
          content: "private file contents"
        }]
      }
    ]).join("\n")

    expect(md).to include('_Display files: [{"name":"data.csv","type":"csv"}]_')
    expect(md).not_to include("/tmp/private")
    expect(md).not_to include("12345")
    expect(md).not_to include("private file contents")
  end

  it "restores lightweight metadata and strips the archive marker from text" do
    text, files = reader.extract_display_files_from_text(
      "Please analyze this\n_Display files: [{\"name\":\"report.pdf\",\"type\":\"pdf\"}]_"
    )

    expect(text).to eq("Please analyze this")
    expect(files).to eq([{ name: "report.pdf", type: "pdf" }])
  end

  it "defaults a missing attachment type without restoring extra fields" do
    _text, files = reader.extract_display_files_from_text(
      '_Display files: [{"name":"notes.txt","path":"/tmp/notes.txt"}]_'
    )

    expect(files).to eq([{ name: "notes.txt", type: "file" }])
  end

  it "archives an inline image as a badge without retaining image data" do
    md = writer.render_message_sections([
      {
        role: "user",
        content: [{
          type: "image_url",
          image_url: { url: "data:image/png;base64,PRIVATE_IMAGE_DATA" },
          image_path: "/tmp/private/photo.png",
          image_name: "photo.png"
        }]
      }
    ]).join("\n")

    expect(md).to include('_Display files: [{"name":"photo.png","type":"image"}]_')
    expect(md).not_to include("PRIVATE_IMAGE_DATA")
    expect(md).not_to include("/tmp/private")
    expect(md).not_to include("[image_url]")
  end

  it "does not mutate the original display metadata while adding image badges" do
    files = [{ name: "report.pdf", type: "pdf" }]
    message = {
      role: "user",
      content: [{ type: "image_url", image_url: { url: "data:image/png;base64,AA==" }, image_name: "photo.png" }],
      display_files: files
    }

    writer.render_message_sections([message])

    expect(files).to eq([{ name: "report.pdf", type: "pdf" }])
  end

  it "stores the original image name as internal multipart metadata" do
    content = Clacky::Agent.allocate.send(
      :format_user_content,
      "",
      [{ url: "data:image/png;base64,AA==", path: "/tmp/random_photo.png", name: "photo.png" }]
    )

    expect(content.first[:image_name]).to eq("photo.png")
  end
end
