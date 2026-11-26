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

    it "prefixes a bare absolute path containing spaces with file://" do
      with_tmp_file("with space.pdf") do |path|
        expect(described_class.normalize("[报告](#{path})")).to eq("[报告](file://#{path})")
      end
    end

    it "prefixes a bare absolute path containing paired parentheses with file://" do
      with_tmp_file("备份(旧).pdf") do |path|
        expect(described_class.normalize("[报告](#{path})")).to eq("[报告](file://#{path})")
      end
    end

    it "handles a path with both spaces and parentheses" do
      with_tmp_file("备份(旧) 副本.pdf") do |path|
        expect(described_class.normalize("[报告](#{path})")).to eq("[报告](file://#{path})")
      end
    end

    it "handles several links with parentheses on one line" do
      with_tmp_file("a(1) b(2).pdf") do |first|
        with_tmp_file("c(3).pdf") do |second|
          content = "[一](#{first}) [二](#{second})"
          expect(described_class.normalize(content))
            .to eq("[一](file://#{first}) [二](file://#{second})")
        end
      end
    end

    it "stops at the closing parenthesis so following text is left alone" do
      with_tmp_file("report.pdf") do |path|
        expect(described_class.normalize("[report](#{path})(见附件)"))
          .to eq("[report](file://#{path})(见附件)")
      end
    end

    it "leaves a path with an unbalanced parenthesis untouched" do
      with_tmp_file("foo(1.pdf") do |path|
        content = "[x](#{path})"
        expect(described_class.normalize(content)).to eq(content)
      end
    end

    it "adds the scheme but keeps angle brackets used for a path with spaces" do
      with_tmp_file("with space.pdf") do |path|
        expect(described_class.normalize("[报告](<#{path}>)")).to eq("[报告](<file://#{path}>)")
      end
    end

    it "keeps angle brackets around a path with parentheses and spaces" do
      with_tmp_file("备份(旧) 副本.pdf") do |path|
        expect(described_class.normalize("[报告](<#{path}>)")).to eq("[报告](<file://#{path}>)")
      end
    end

    it "still normalizes an existing file:// link inside angle brackets" do
      with_tmp_file("with space.pdf") do |path|
        expect(described_class.normalize("[报告](<file://#{path}>)")).to eq("[报告](<file://#{path}>)")
      end
    end
  end

  describe ".extract_file_links" do
    it "returns bare and angle-bracket file links in order with their inline flag" do
      content = "![图](<file:///tmp/a/x y.png>) 和 [文](file:///tmp/a/备份(旧) 副本.pdf)"
      expect(described_class.extract_file_links(content)).to eq([
        { inline: true,  path: "/tmp/a/x y.png" },
        { inline: false, path: "/tmp/a/备份(旧) 副本.pdf" }
      ])
    end

    it "ignores links that are not file://" do
      content = "[站点](https://example.com/a(b)) [路由](/docs/start) [锚](<#top>)"
      expect(described_class.extract_file_links(content)).to eq([])
    end

    it "returns an empty list for nil and empty content" do
      expect(described_class.extract_file_links(nil)).to eq([])
      expect(described_class.extract_file_links("")).to eq([])
    end
  end
end
