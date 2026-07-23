# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# rubocop:disable Metrics/BlockLength
RSpec.describe "CLACKY_HOME path policy" do
  project_root = File.expand_path("../..", __dir__)
  canonical_fallback = File.join(project_root, "lib", "clacky.rb")
  forbidden_patterns = [
    %r{File\.expand_path\(["']~/\.clacky},
    /File\.join\(Dir\.home,\s*["']\.clacky["']/,
    /Pathname\.new.*ENV.*HOME.*\.clacky/,
    /Dir\.home.*\.clacky/
  ].freeze

  it "routes runtime data paths through Clacky.data_dir" do
    violations = Dir[File.join(project_root, "lib", "**", "*.rb")].each_with_object([]) do |path, results|
      File.readlines(path).each_with_index do |line, index|
        next unless forbidden_patterns.any? { |pattern| pattern.match?(line) }
        next if path == canonical_fallback && line.include?('ENV["CLACKY_HOME"]')

        results << "#{path.delete_prefix("#{project_root}/")}:#{index + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty, <<~MESSAGE
      Runtime paths must use Clacky.data_dir so CLACKY_HOME is honored:
      #{violations.join("\n")}
    MESSAGE
  end

  it "initializes representative runtime paths below CLACKY_HOME" do
    custom_home = File.join(Dir.tmpdir, "clacky-custom-home")
    script = <<~'RUBY'
      require "json"
      require "clacky"
      require "clacky/server/scheduler"

      puts JSON.generate([
        Clacky.data_dir,
        Clacky::AgentProfile::USER_AGENTS_DIR,
        Clacky::ExtensionLoader::INSTALLED_DIR,
        Clacky::ExtensionLoader::LOCAL_DIR,
        Clacky::ExtensionLoader::DISABLED_FILE,
        Clacky::ExtensionLoader::DATA_DIR,
        Clacky::ShellHookLoader::DEFAULT_PATH,
        Clacky::Agent::MemoryUpdater::MEMORIES_DIR,
        Clacky::Server::BackupManager::CLACKY_DIR,
        Clacky::Server::Scheduler::SCHEDULES_FILE,
        Clacky::Utils::ParserManager::PARSERS_DIR,
        Clacky::Utils::ScriptsManager::SCRIPTS_DIR
      ])
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "CLACKY_HOME" => custom_home },
      RbConfig.ruby,
      "-I#{File.join(project_root, "lib")}",
      "-e",
      script
    )

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to all(start_with(custom_home))
  end

  it "loads Clacky before standalone skill scripts use Clacky.data_dir" do
    standalone_scripts = %w[
      lib/clacky/default_skills/channel-manager/discord_setup.rb
      lib/clacky/default_skills/channel-manager/weixin_setup.rb
    ]

    standalone_scripts.each do |relative_path|
      source = File.read(File.join(project_root, relative_path))
      expect(source).to include('require "clacky"'), "#{relative_path} must load Clacky"
    end
  end
end
# rubocop:enable Metrics/BlockLength
