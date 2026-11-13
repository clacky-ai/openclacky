# frozen_string_literal: true

RSpec.describe "Project name hover scroll" do
  let(:web_dir) { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:projects) { File.read(File.join(web_dir, "projects.js")) }
  let(:sessions) { File.read(File.join(web_dir, "sessions.js")) }
  let(:styles) { File.read(File.join(web_dir, "app.css")) }

  it "wraps the project name in a viewport and a sliding content layer" do
    expect(projects).to include('nameEl.className = "project-name";')
    expect(projects).to include('nameText.className = "project-name__content";')
    expect(projects).to include("nameEl.appendChild(nameText);")
    expect(projects).to include("header.appendChild(nameEl);")
  end

  it "reuses the shared hover-scroll helper instead of reimplementing it" do
    expect(projects).to include("Sessions._setupHorizontalTextOverflow(header, {")
    expect(projects).to include('viewportSelector: ".project-name",')
    expect(projects).to include('contentSelector: ".project-name__content",')
    expect(projects).to include('activeClass: "project-name-scrolling",')
    expect(projects).to include('fadeClass: "project-name-leading-fade",')
    expect(projects).to include('distanceProperty: "--project-name-scroll-distance",')
    expect(projects).to include('durationProperty: "--project-name-scroll-duration",')
  end

  it "exposes the helper on the Sessions public API" do
    expect(sessions).to include("_setupHorizontalTextOverflow,")
  end

  it "fades the tail with a mask and slides the content on hover" do
    expect(styles).to include(
      ".project-name__content {\n" \
      "  display: inline-block;\n" \
      "  min-width: max-content;"
    )
    expect(styles).to include(
      ".project-group-header.project-name-scrolling .project-name__content {\n" \
      "  transform: translateX(calc(-1 * var(--project-name-scroll-distance)));"
    )
    expect(styles).to include(
      ".project-group-header.project-name-leading-fade .project-name {\n" \
      "  -webkit-mask-image: linear-gradient(to right, transparent, #000 1rem, " \
      "#000 calc(100% - 1rem), transparent);"
    )
    expect(styles).to include(
      "  -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 1rem), transparent);\n" \
      "  mask-image: linear-gradient(to right, #000 calc(100% - 1rem), transparent);\n" \
      "}\n" \
      "/* Overlong names slide left on hover"
    )
  end

  it "drops the ellipsis truncation that the issue complains about" do
    project_name_block = styles[/\.project-name \{\n(.*?)\n\}/m, 1]

    expect(project_name_block).not_to include("text-overflow: ellipsis")
  end

  it "stops the slide for users who prefer reduced motion" do
    expect(styles).to include(
      "  .project-name__content {\n" \
      "    transition-duration: 0s !important;\n" \
      "    transition-delay: 0s !important;\n" \
      "  }"
    )
  end
end
