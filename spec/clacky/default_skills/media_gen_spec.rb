# frozen_string_literal: true

require "tmpdir"

RSpec.describe "media-gen default skill" do
  let(:skill_dir) do
    File.expand_path("../../../lib/clacky/default_skills/media-gen", __dir__)
  end

  it "includes the current session ID in every media request" do
    skill = Clacky::Skill.new(skill_dir)
    result = skill.process_content(template_context: { "session_id" => "session-123" })

    expect(result.scan('"session_id": "session-123"').size).to eq(4)
    expect(result).to include('"Continuing the same scene, the camera keeps pushing forward…" "session-123"')
  end

  it "includes the session ID in chained-video payloads" do
    Dir.mktmpdir do |tmpdir|
      bin_dir = File.join(tmpdir, "bin")
      frame = File.join(tmpdir, "frame.jpg")
      payload = File.join(tmpdir, "payload.json")
      FileUtils.mkdir_p(bin_dir)
      File.write(File.join(bin_dir, "ffprobe"), "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "ffprobe"))
      File.binwrite(frame, "frame-data")

      script = File.join(skill_dir, "scripts", "video_seq.sh")
      env = { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH", "")}" }
      success = system(env, "/bin/bash", script, "payload", payload, frame,
                       "8", "landscape", tmpdir, "continue scene", "session-123",
                       out: File::NULL, err: File::NULL)

      expect(success).to be true
      expect(JSON.parse(File.read(payload))["session_id"]).to eq("session-123")
    end
  end
end
