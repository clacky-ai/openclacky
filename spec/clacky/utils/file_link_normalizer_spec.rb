# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/file_link_normalizer"

RSpec.describe Clacky::Utils::FileLinkNormalizer do
  def with_tmp_file(name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, "x")
      yield path
    end
  end

  def project_ref(decoded)
    "/workspace/projects/#{Base64.urlsafe_encode64(decoded, padding: false)}"
  end

  describe ".normalize" do
    it "decodes a hosted-platform project ref back to a file:// link" do
      with_tmp_file("报告.pdf") do |path|
        expect(described_class.normalize("[报告](#{project_ref("cch1:file://#{path}")})"))
          .to eq("[报告](file://#{path})")
      end
    end

    it "decodes a project ref wrapped in the local server origin" do
      with_tmp_file("report.pdf") do |path|
        ref = project_ref("cch1:file://#{path}")
        expect(described_class.normalize("[report](http://127.0.0.1:7070#{ref})"))
          .to eq("[report](file://#{path})")
      end
    end

    it "prefixes a bare absolute path with file://" do
      with_tmp_file("report.pdf") do |path|
        expect(described_class.normalize("[report](#{path})")).to eq("[report](file://#{path})")
      end
    end

    it "leaves an existing file:// link untouched" do
      with_tmp_file("report.pdf") do |path|
        expect(described_class.normalize("[report](file://#{path})")).to eq("[report](file://#{path})")
      end
    end

    it "leaves paths that do not exist locally untouched" do
      content = "[x](/tmp/definitely-missing-#{SecureRandom.hex(6)}.pdf)"
      expect(described_class.normalize(content)).to eq(content)
    end

    it "does not touch site routes or external links" do
      content = "[api](/api/sessions) [docs](/docs/getting-started) [web](https://example.com/a) [mail](mailto:a@b.c)"
      expect(described_class.normalize(content)).to eq(content)
    end

    it "keeps a malformed project ref as-is" do
      content = "[x](/workspace/projects/!!!not-base64)"
      expect(described_class.normalize(content)).to eq(content)
    end

    it "returns nil and empty content unchanged" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("")).to eq("")
    end
  end
end
