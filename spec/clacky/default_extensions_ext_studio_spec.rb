# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ExtStudioExt API handler" do
  let(:ext_dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(ext_dir, "ext.yml") }
  let(:loader_result) { double("loader result", containers: { "demo" => { dir: ext_dir } }) }
  let(:handler_class) do
    Clacky::ApiExtension.reset_registry!
    handler_path = File.expand_path("../../lib/clacky/default_extensions/ext-studio/api/handler.rb", __dir__)
    load(handler_path, true)
    Clacky::ApiExtension.pending_subclasses.last
  end
  let(:route) do
    handler_class.routes.find do |candidate|
      candidate.method == :post && candidate.pattern == "/set_version"
    end
  end

  before do
    File.write(manifest_path, "id: demo\nversion: 1.0.0\ncontributes: {}\n")
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(loader_result)
  end

  after do
    FileUtils.remove_entry(ext_dir) if Dir.exist?(ext_dir)
    Clacky::ApiExtension.reset_registry!
  end

  def invoke_set_version(version)
    req = double("request", body: JSON.generate(ext_id: "demo", version: version))
    instance = handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil)
    instance.invoke
  end

  it "writes a valid three-segment numeric version" do
    expect { invoke_set_version("10.2.35") }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include("version" => "10.2.35")
    end

    expect(File.read(manifest_path)).to include("version: 10.2.35")
  end

  it "rejects an invalid version without changing ext.yml" do
    original = File.read(manifest_path)

    ["测试test", "1.0", "1..0", "1.0.0.1"].each do |version|
      expect { invoke_set_version(version) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(422)
        expect(JSON.parse(halt.payload)["error"]).to match(/1\.0\.0/)
      end
    end

    expect(File.read(manifest_path)).to eq(original)
  end
end

RSpec.describe "ExtStudioExt creator navigation" do
  let(:view_source) do
    File.read(File.expand_path(
      "../../lib/clacky/default_extensions/ext-studio/panels/studio/view.js",
      __dir__
    ))
  end

  it "hides the creator center for branded non-owners using the existing permission flags" do
    expect(view_source).to include(
      'const brandNonAdmin = typeof Brand !== "undefined" && Brand.branded && !Brand.userLicensed;'
    )
    expect(view_source).to include("creatorNavItem.hidden = !brandStatusReady || brandNonAdmin;")
  end

  it "updates the navigation after brand status is resolved" do
    expect(view_source).to include('Brand.on("brand:status", function () {')
    expect(view_source).to include("brandStatusReady = true;")
    expect(view_source).to include("syncCreatorNavVisibility();")
  end
end

RSpec.describe "ExtStudioExt brand owner publishing" do
  let(:view_source) do
    File.read(File.expand_path(
      "../../lib/clacky/default_extensions/ext-studio/panels/studio/view.js",
      __dir__
    ))
  end
  let(:handler_source) do
    File.read(File.expand_path(
      "../../lib/clacky/default_extensions/ext-studio/api/handler.rb",
      __dir__
    ))
  end

  it "uses the existing brand owner flags to select the publishing experience" do
    expect(view_source).to include(
      'return typeof Brand !== "undefined" && Brand.branded && Brand.userLicensed;'
    )
  end

  it "shows only the matching publication channel in the session publish panel" do
    expect(view_source).to include(
      'const endpoint = brandOwner ? "/published_brand" : "/published";'
    )
    expect(view_source).to include(
      ': (data.extensions || []).filter((e) => e.origin !== "self");'
    )
    expect(view_source).to include(
      'class: "studio-btn studio-btn-primary studio-publish-brand-btn"'
    )
  end

  it "hides the marketplace section and promotes brand publishing in the creator center" do
    expect(view_source).to include('if (!isBrandOwner()) {')
    expect(view_source).to include(
      'text: brandEntry ? t("extlist.btn.updateBrand") : t("extlist.btn.publishBrand")'
    )
    expect(view_source).to include(
      'brandPub.addEventListener("click", () => doPublish(ext, brandEntry ? brandEntry.version : null, "self"));'
    )
  end

  it "lists the complete brand distribution for owners without exposing global unpublish for marketplace entries" do
    expect(view_source).to include(
      'brandPublished = isBrandOwner() ? brandCloud : cloud.filter((e) => e.origin === "self");'
    )
    expect(view_source).to include(
      'const canUnpublish = !isBrandOwner() || ext.origin === "self";'
    )
    expect(view_source).to include('if (!brandOwner || e.origin === "self") {')
  end

  it "preserves extension origin in the brand distribution response" do
    published_brand_route = handler_source.split('get "/published_brand" do', 2).last
                                          .split('delete "/local" do', 2).first

    expect(published_brand_route).to include('origin: ext["origin"]')
  end
end
