# frozen_string_literal: true

require "open3"
require "json"

RSpec.describe "Web composer slash-command detection" do
  let(:script) { File.expand_path("../../support/slash_command_test.js", __dir__) }
  let(:source) { File.read(File.expand_path("../../../lib/clacky/web/skills.js", __dir__)) }

  it "keeps the palette off pasted paths and never swallows Enter" do
    output, status = Open3.capture2e("node", script)
    expect(status.success?).to be(true), output
  end

  it "routes every slash check through the single parser" do
    # Two competing regexes in this file was the bug: the palette used one and the
    # sent-message highlighter another, so a path could pass one and fail the other.
    expect(source.scan(%r{/\^\\/}).size).to eq(1)
    expect(source).to include("function _slashCommandName(")
    expect(source).not_to match(%r{text\.match\(/\^\\/\(\\S\+\)/\)})
  end

  describe "parity with the backend parser" do
    # The client must agree with parse_skill_command on what counts as a command.
    # A more permissive client pops the palette over text the server treats as an
    # ordinary message — which is exactly how a pasted path became unsendable.
    let(:parser) do
      loader = instance_double(Clacky::SkillLoader)
      allow(loader).to receive(:find_by_command).and_return(nil)
      obj = Object.new
      obj.extend(Clacky::Agent::SkillManager)
      obj.instance_variable_set(:@skill_loader, loader)
      obj.instance_variable_set(:@agent_profile, nil)
      obj
    end

    def client_table
      js = File.read(File.expand_path("../../support/slash_command_test.js", __dir__))
      %w[COMMANDS PLAIN_MESSAGES].map do |const|
        body = js[/^const #{const} = \[(.*?)^\];/m, 1]
        raise "#{const} table not found in the JS harness" unless body

        JSON.parse("[#{body.gsub(/,\s*\z/m, '')}]")
      end
    end

    it "agrees on which inputs are commands" do
      commands, = client_table
      commands.each do |input|
        # An IME's full-width slash is normalized in the composer before the text
        # ever reaches the server, so compare the normalized form.
        normalized = input.sub(/\A[／、]/, "/")
        expect(parser.parse_skill_command(normalized)[:matched]).to be(true), input.inspect
      end
    end

    it "agrees on which inputs are plain messages" do
      _, plain = client_table
      plain.each do |input|
        expect(parser.parse_skill_command(input)[:matched]).to be(false), input.inspect
      end
    end

    it "rejects a pasted absolute path on both sides" do
      expect(parser.parse_skill_command("/Users/jiujiu/Download")[:matched]).to be(false)
    end
  end
end
