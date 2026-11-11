# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Server::HttpServer, "backup restore" do
  let(:home)       { Dir.mktmpdir("clacky-restore-home") }
  let(:clacky_dir) { File.join(home, ".clacky") }
  let(:response)   { WEBrick::HTTPResponse.new(WEBrick::Config::HTTP) }
  let(:request)    { double("request") }
  let(:server) do
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@master_pid, nil)
    end
  end

  around do |example|
    original = ENV["HOME"]
    ENV["HOME"] = home
    begin
      example.run
    ensure
      ENV["HOME"] = original
      FileUtils.rm_rf(home)
    end
  end

  before do
    FileUtils.mkdir_p(clacky_dir)
    File.write(File.join(clacky_dir, "config.yml"), "old: true\n")
    allow(Clacky::ThreadRegistry).to receive(:spawn)
    allow(server).to receive(:standalone_exec_restart)
  end

  def build_archive(dir)
    src = File.join(dir, "src")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "config.yml"), "restored: true\n")
    archive = File.join(dir, "backup.tar.gz")
    system("tar", "-czf", archive, "-C", src, ".") or raise "tar failed"
    archive
  end

  def stream_from(path)
    allow(request).to receive(:body) do |&blk|
      File.open(path, "rb") do |f|
        while (chunk = f.read(64 * 1024))
          blk.call(chunk)
        end
      end
    end
  end

  it "streams the upload to disk and swaps it in" do
    stream_from(build_archive(home))

    server.send(:api_backup_restore, request, response)

    expect(response.status).to eq(200)
    expect(File.read(File.join(clacky_dir, "config.yml"))).to eq("restored: true\n")
    expect(Dir.glob(File.join(home, ".clacky-restore-*"))).to be_empty
    expect(Dir.glob(File.join(home, ".clacky-pre-restore-*")).size).to eq(1)
  end

  it "rejects a non-gzip upload without touching the existing tree" do
    bogus = File.join(home, "bogus.tar.gz")
    File.binwrite(bogus, "definitely not gzip")
    stream_from(bogus)

    server.send(:api_backup_restore, request, response)

    expect(response.status).to eq(400)
    expect(File.read(File.join(clacky_dir, "config.yml"))).to eq("old: true\n")
  end

  it "keeps the old tree when extraction fails" do
    broken = File.join(home, "broken.tar.gz")
    File.binwrite(broken, "\x1F\x8B".b + "garbage" * 10)
    stream_from(broken)

    server.send(:api_backup_restore, request, response)

    expect(response.status).to eq(500)
    expect(File.read(File.join(clacky_dir, "config.yml"))).to eq("old: true\n")
    expect(Dir.glob(File.join(home, ".clacky-restore-*"))).to be_empty
  end
end
