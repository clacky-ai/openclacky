# frozen_string_literal: true

require "json"
require "rbconfig"

RSpec.describe "channel-manager qq_setup.rb" do
  let(:script) do
    File.expand_path("../../../../../lib/clacky/default_skills/channel-manager/qq_setup.rb", __FILE__)
  end

  def run(*args)
    out = IO.popen([RbConfig.ruby, script, *args], err: [:child, :out], &:read)
    [out, $?.exitstatus]
  rescue => e
    [e.message, -1]
  end

  it "prints the portal URL with --portal-url" do
    out, status = run("--portal-url")
    expect(status).to eq(0)
    expect(out.strip).to eq("https://q.qq.com")
  end

  it "prints usage and exits 2 with no arguments" do
    out, status = run
    expect(status).to eq(2)
    expect(out).to include("Usage:")
  end

  it "rejects an unknown mode" do
    _out, status = run("--bogus")
    expect(status).to eq(2)
  end

  it "reports a JSON error when the pair is incomplete" do
    out, status = run("--validate", "only-id")
    expect(status).to eq(1)
    data = JSON.parse(out)
    expect(data["ok"]).to be(false)
    expect(data["error"]).to include("missing app_id")
  end

  it "accepts --sandbox without using it for the token host (flag is a no-op)", :network do
    # Validation always hits the shared token endpoint; a bogus credential pair
    # gets a well-formed JSON error from the real API rather than a 404.
    out, status = run("--validate", "000000 definitely-not-a-secret", "--sandbox")
    data = JSON.parse(out)
    expect(status).to eq(1)
    expect(data["ok"]).to be(false)
    # The sandbox host returned 11001/不支持的调用 before the fix; the shared
    # endpoint answers with an auth error instead.
    expect(data["error"]).not_to include("不支持的调用")
  end
end
