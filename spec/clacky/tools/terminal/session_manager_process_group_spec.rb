# frozen_string_literal: true

# Regression tests for issue #485: kill_all! must reap the whole PTY
# process group, not just the leader, so background `&` jobs and other
# grandchildren don't outlive the openclacky process.

RSpec.describe Clacky::Tools::Terminal::SessionManager, "process group cleanup (#485)" do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:killed) { @killed ||= [] }

  before do
    counter = 100_000
    allow(described_class).to receive(:register).and_wrap_original do |orig, **kw|
      counter += 1
      orig.call(**kw.merge(pid: counter))
    end
    allow(Process).to receive(:kill) do |sig, target|
      killed << [sig, target]
      1
    end
  end

  def make_session
    described_class.register(
      command: "bash -l -i",
      cwd: Dir.pwd,
      log_file: "/dev/null",
      log_io: File.open("/dev/null", "wb"),
      reader: File.open("/dev/null", "rb"),
      writer: File.open("/dev/null", "wb"),
      reader_thread: Thread.new { sleep 60 },
      mode: "shell",
    )
  end

  it "signals the whole process group (negative pid)" do
    s = make_session
    described_class.kill_all!
    expect(killed).to include(["KILL", -s.pid])
  end

  it "skips sessions that are already exited or killed" do
    a = make_session
    b = make_session
    a.status = "exited"
    b.status = "killed"
    described_class.kill_all!
    expect(killed).to be_empty
  end
end
