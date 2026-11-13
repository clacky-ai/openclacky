# frozen_string_literal: true

require "open3"

# A syntax error kills the entire script, and the failure is silent: the page
# still loads, the feature it provides just never appears. Source-string specs
# cannot catch that, so hand the files to a real parser instead.
RSpec.describe "JavaScript sources" do
  web_dir  = File.expand_path("../../../lib/clacky/web", __dir__)
  ext_dir  = File.expand_path("../../../lib/clacky/default_extensions", __dir__)
  js_files = Dir[File.join(web_dir, "*.js")] + Dir[File.join(ext_dir, "**", "*.js")]

  node = `command -v node 2>/dev/null`.strip

  it "has something to check" do
    expect(js_files).not_to be_empty
  end

  js_files.sort.each do |path|
    it "parses #{path.sub(File.expand_path("../../../lib/clacky/", __dir__), "")}" do
      skip "node is not installed" if node.empty?

      _out, err, status = Open3.capture3(node, "--check", path)
      expect(status.success?).to be(true), err
    end
  end
end
