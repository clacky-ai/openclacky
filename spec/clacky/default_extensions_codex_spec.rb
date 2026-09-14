# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "rbconfig"
require "timeout"
require "digest"

RSpec.describe "bundled Codex extension" do
  let(:codex_dir) do
    File.join(Clacky::ExtensionLoader::BUILTIN_DIR, "codex")
  end

  before do
    allow(Clacky::ExtensionLoader).to receive(:disabled_ids).and_return(Set.new)
  end

  after do
    Clacky::ExtensionLoader.invalidate_cache!
  end

  it "is enabled by default and contributes its provider, runtime, and status API" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    container = result.containers["codex"]
    provider = result.providers.find { |unit| unit.id == "codex" }
    runtime = result.agent_runtimes.find { |unit| unit.id == "codex" }
    api = result.api.find { |unit| unit.id == "codex" }

    expect(container).not_to be_nil
    expect(container[:disabled]).to be false
    expect(result.errors.select { |error| error.ext_id == "codex" }).to be_empty
    expect(provider.spec).to include(
      "name" => "ChatGPT",
      "name_key" => "provider.name.codex",
      "runtime_id" => "codex",
      "auth_mode" => "runtime",
      "credential_fields" => [],
      "dynamic_models" => "discovery"
    )
    expect(runtime.spec).to include(
      "adapter" => "runtime.rb",
      "class" => "Clacky::DefaultExtensions::Codex::Runtime"
    )
    expect(api.spec["handler"]).to eq("api/handler.rb")
  end

  it "is visible through the provider registry before any model is configured" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::ProviderRegistry.new(extension_units: result.providers)

    expect(registry["codex"]).to include(
      "runtime_id" => "codex",
      "auth_mode" => "runtime",
      "dynamic_models" => "discovery"
    )
    expect(registry["codex"]["display_model"]).to be_nil
    expect(registry.runtime_id_for("codex")).to eq("codex")
  end

  it "ships a loadable runtime adapter shell" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::AgentRuntimeRegistry.new(extension_units: result.agent_runtimes)

    runtime = registry.build("codex", session_id: "session-1")

    expect(runtime).to be_a(Clacky::DefaultExtensions::Codex::Runtime)
  end
end

RSpec.describe "Codex managed home" do
  let(:tmpdir) { Dir.mktmpdir("clacky-codex-home") }
  let(:source_home) { File.join(tmpdir, "source") }
  let(:managed_home) { File.join(tmpdir, "managed") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def codex_home_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "codex_home.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex home manager at #{path}"
    require path
    Clacky::DefaultExtensions::Codex::CodexHome
  end

  def write_secure_auth(path, content = "private-auth-material")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.chmod(0o600, path)
    path
  end

  def build_home(**options)
    codex_home_class.new(
      **{
        managed_home: managed_home,
        source_home: source_home,
        platform: RUBY_PLATFORM,
        current_uid: Process.uid
      }.merge(options)
    )
  end

  it "creates the managed directory with mode 0700" do
    FileUtils.mkdir_p(source_home)

    result = build_home.prepare

    expect(result.managed_home).to eq(File.expand_path(managed_home))
    expect(File.stat(managed_home).mode & 0o777).to eq(0o700)
    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
    expect(File.stat(File.join(managed_home, "config.toml")).mode & 0o777).to eq(0o600)
  end

  it "rejects an overlapping source and managed home before changing source files" do
    shared_home = File.join(tmpdir, "shared-codex-home")
    FileUtils.mkdir_p(shared_home)
    source_config = File.join(shared_home, "config.toml")
    source_auth = File.join(shared_home, "auth.json")
    config_content = "model = \"gpt-5.6-sol\"\n[mcp_servers.private]\ncommand = \"keep-me\"\n"
    File.write(source_config, config_content)
    File.write(source_auth, "private-auth-material")
    File.chmod(0o600, source_config)
    File.chmod(0o600, source_auth)

    expect do
      build_home(managed_home: shared_home, source_home: shared_home).prepare
    end.to raise_error(
      codex_home_class::UnsafeManagedHomeError,
      /source.*managed|managed.*source/i
    )

    expect(File.binread(source_config)).to eq(config_content)
    expect(File.binread(source_auth)).to eq("private-auth-material")
    expect(File.exist?("#{shared_home}.prepare.lock")).to be(false)
  end

  it "rejects nesting the managed home inside the source home" do
    FileUtils.mkdir_p(source_home)
    nested_managed_home = File.join(source_home, "openclacky-managed")

    expect do
      build_home(managed_home: nested_managed_home).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.exist?(nested_managed_home)).to be(false)
    expect(File.exist?("#{nested_managed_home}.prepare.lock")).to be(false)
  end

  it "rejects nesting the source home inside the managed home" do
    nested_source_home = File.join(managed_home, "source")
    FileUtils.mkdir_p(nested_source_home)

    expect do
      build_home(source_home: nested_source_home).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.exist?(File.join(managed_home, "config.toml"))).to be(false)
    expect(File.exist?("#{managed_home}.prepare.lock")).to be(false)
  end

  it "rejects source and managed homes that resolve to the same directory" do
    shared_home = File.join(tmpdir, "shared-codex-home")
    aliased_source_home = File.join(tmpdir, "source-alias")
    FileUtils.mkdir_p(shared_home)
    File.symlink(shared_home, aliased_source_home)
    source_config = File.join(shared_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")

    expect do
      build_home(
        managed_home: shared_home,
        source_home: aliased_source_home
      ).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.binread(source_config)).to eq("model = \"gpt-5.6-sol\"\n")
    expect(File.exist?("#{shared_home}.prepare.lock")).to be(false)
  end

  it "imports only safe top-level Codex model preferences" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      notify = ["run-untrusted-program"]
      service_tier = "priority" # preserve the user's account tier
      model = "gpt-5.6-sol"
      model_reasoning_effort = "ultra"

      [mcp_servers.evil]
      command = "steal-secrets"
    TOML
    File.chmod(0o644, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(<<~TOML)
      cli_auth_credentials_store = "auto"
      service_tier = "priority"
      model = "gpt-5.6-sol"
      model_reasoning_effort = "ultra"
    TOML
  end

  it "accepts safe literal-string model preferences" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = 'gpt-5.6-sol'\n")
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to include(
      %(model = "gpt-5.6-sol")
    )
  end

  it "does not follow a source config symlink" do
    FileUtils.mkdir_p(source_home)
    outside = File.join(tmpdir, "outside-source-config.toml")
    File.write(outside, "model = \"gpt-5.6-sol\"\n")
    File.symlink(outside, File.join(source_home, "config.toml"))

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "ignores a source config writable by another user" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o622, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "ignores model preferences from an unsafe source home" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o600, source_config)
    File.chmod(0o777, source_home)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "does not parse model-looking lines inside multiline TOML strings" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      description = """
      model = "gpt-5.6-sol"
      """
    TOML
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "rejects quoted or dotted keys that conflict with imported preferences" do
    [
      %(model = "gpt-5.6-sol"\n"model" = "gpt-5.5"\n),
      %(model = "gpt-5.6-sol"\nmodel.name = "gpt-5.5"\n)
    ].each do |content|
      FileUtils.rm_rf(managed_home)
      FileUtils.mkdir_p(source_home)
      source_config = File.join(source_home, "config.toml")
      File.write(source_config, content)
      File.chmod(0o600, source_config)

      build_home.prepare

      expect(File.read(File.join(managed_home, "config.toml"))).to eq(
        "cli_auth_credentials_store = \"auto\"\n"
      )
    end
  end

  it "rejects preference-looking lines inside a multiline top-level value" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      notify = [
      model = "gpt-5.6-sol"
      ]
    TOML
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "reads preferences from the opened file descriptor if the path is replaced" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    original_config = File.join(source_home, "original-config.toml")
    replacement_config = File.join(tmpdir, "replacement-config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.write(replacement_config, "model = \"gpt-5.5\"\n")
    File.chmod(0o600, source_config)
    File.chmod(0o600, replacement_config)
    source_config_opener = lambda do |path, flags, &block|
      File.open(path, flags) do |file|
        File.rename(path, original_config)
        File.symlink(replacement_config, path)
        block.call(file)
      end
    end

    build_home(source_config_opener: source_config_opener).prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to include(
      %(model = "gpt-5.6-sol")
    )
    expect(File.read(File.join(managed_home, "config.toml"))).not_to include(
      %(model = "gpt-5.5")
    )
  end

  it "rejects a different regular file installed before the opener reads it" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    original_config = File.join(source_home, "original-config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o600, source_config)
    source_config_opener = lambda do |path, flags, &block|
      File.rename(path, original_config)
      File.write(path, "model = \"gpt-5.5\"\n")
      File.chmod(0o600, path)
      File.open(path, flags, &block)
    end

    build_home(source_config_opener: source_config_opener).prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "rejects a managed home below an ancestor owned by another user" do
    FileUtils.mkdir_p(managed_home)
    untrusted_ancestor = File.expand_path(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == untrusted_ancestor

      Struct.new(:uid, :mode).new(Process.uid + 1, stat.mode)
    end

    expect { build_home(managed_stat_reader: stat_reader).prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError, /owner/i)
  end

  it "rejects a managed home below a user-writable shared ancestor" do
    FileUtils.mkdir_p(managed_home)
    writable_ancestor = File.expand_path(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == writable_ancestor

      Struct.new(:uid, :mode).new(Process.uid, stat.mode | 0o020)
    end

    expect { build_home(managed_stat_reader: stat_reader).prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError, /permissions/i)
  end

  it "rejects a managed home reached through a symlinked ancestor" do
    real_parent = File.join(tmpdir, "real-parent")
    linked_parent = File.join(tmpdir, "linked-parent")
    FileUtils.mkdir_p(real_parent)
    File.symlink(real_parent, linked_parent)

    expect do
      build_home(managed_home: File.join(linked_parent, "codex")).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /symlink/i)
  end

  it "keeps the default managed home outside OpenClacky's credential directory" do
    fake_home = File.join(tmpdir, "user-home")
    allow(Dir).to receive(:home).and_return(fake_home)

    result = codex_home_class.new(
      source_home: source_home,
      platform: "arm64-darwin",
      current_uid: Process.uid
    ).prepare

    expect(result.managed_home).to eq(
      File.join(fake_home, "Library", "Application Support", "OpenClacky", "codex")
    )
    expect(result.managed_home).not_to start_with(File.join(fake_home, ".clacky"))
  end

  it "refuses to replace a managed config symlink" do
    FileUtils.mkdir_p(managed_home)
    outside = File.join(tmpdir, "outside-config.toml")
    File.write(outside, "do-not-replace\n")
    File.symlink(outside, File.join(managed_home, "config.toml"))

    expect { build_home.prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError)
    expect(File.read(outside)).to eq("do-not-replace\n")
  end

  it "reuses a secure same-user auth.json through a symlink without reading or copying it" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home.prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(result.auth_reused).to be true
    expect(result.auth_reason).to eq("reused")
    expect(File.symlink?(managed_auth)).to be true
    expect(File.realpath(managed_auth)).to eq(File.realpath(source_auth))
    expect(File.read(source_auth)).to eq("private-auth-material")
    expect(result.protected_auth_paths).to include(
      File.expand_path(managed_auth),
      File.expand_path(source_auth)
    )
    expect(result.protected_paths).to include(
      File.expand_path(source_home),
      File.join(Dir.home, ".clacky"),
      File.join(Dir.home, ".ssh")
    )
  end

  it "protects common credential stores outside the Codex home" do
    FileUtils.mkdir_p(source_home)

    result = build_home.prepare

    expect(result.protected_paths).to include(
      File.join(Dir.home, ".config", "gh"),
      File.join(Dir.home, ".config", "glab-cli"),
      File.join(Dir.home, ".cargo", "credentials"),
      File.join(Dir.home, ".cargo", "credentials.toml"),
      File.join(Dir.home, ".gem", "credentials"),
      File.join(Dir.home, ".pypirc"),
      File.join(Dir.home, ".terraform.d"),
      File.join(Dir.home, ".config", "rclone"),
      File.join(Dir.home, ".kaggle"),
      File.join(Dir.home, ".cache", "huggingface", "token"),
      File.join(Dir.home, ".huggingface")
    )
  end

  it "updates its managed link when the selected Codex home changes" do
    first_home = File.join(tmpdir, "first-source")
    second_home = File.join(tmpdir, "second-source")
    first_auth = write_secure_auth(File.join(first_home, "auth.json"), "first-login")
    second_auth = write_secure_auth(File.join(second_home, "auth.json"), "second-login")

    build_home(source_home: first_home).prepare
    result = build_home(source_home: second_home).prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(File.realpath(managed_auth)).not_to eq(File.realpath(first_auth))
    expect(File.realpath(managed_auth)).to eq(File.realpath(second_auth))
    expect(result.auth_reused).to be(true)
  end

  it "does not inherit source configuration, plugins, skills, MCP data, or history" do
    write_secure_auth(File.join(source_home, "auth.json"))
    File.write(
      File.join(source_home, "config.toml"),
      "[mcp_servers.evil]\nmodel = \"gpt-from-mcp-table\"\n"
    )
    %w[plugins skills rules history sessions].each do |name|
      FileUtils.mkdir_p(File.join(source_home, name))
      File.write(File.join(source_home, name, "sentinel"), "do-not-inherit")
    end

    build_home.prepare

    expect(Dir.children(managed_home)).to contain_exactly("auth.json", "config.toml")
    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "rejects a source auth.json that is itself a symlink" do
    outside = write_secure_auth(File.join(tmpdir, "outside-auth.json"))
    FileUtils.mkdir_p(source_home)
    File.symlink(outside, File.join(source_home, "auth.json"))

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("source_symlink")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "rejects a source home that is a symlink" do
    real_home = File.join(tmpdir, "real-source")
    write_secure_auth(File.join(real_home, "auth.json"))
    linked_home = File.join(tmpdir, "linked-source")
    File.symlink(real_home, linked_home)

    result = build_home(source_home: linked_home).prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("source_home_symlink")
  end

  it "rejects a source home writable by other users" do
    write_secure_auth(File.join(source_home, "auth.json"))
    File.chmod(0o777, source_home)

    result = build_home.prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("insecure_source_home")
  end

  it "rejects a source path controlled by another non-root user" do
    write_secure_auth(File.join(source_home, "auth.json"))
    untrusted_ancestor = File.realpath(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == untrusted_ancestor

      Struct.new(:uid, :mode).new(Process.uid + 1, stat.mode)
    end

    result = build_home(stat_reader: stat_reader).prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("untrusted_source_home_owner")
  end

  it "rejects group- or world-accessible auth files" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))
    File.chmod(0o644, source_auth)

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("insecure_permissions")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "rejects an auth file not owned by the expected user" do
    write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home(current_uid: Process.uid + 1).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("wrong_owner")
  end

  it "rejects an explicitly supplied auth source outside the selected Codex home" do
    FileUtils.mkdir_p(source_home)
    outside = write_secure_auth(File.join(tmpdir, "outside-auth.json"))

    result = build_home(source_auth_path: outside).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("outside_source_home")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "does not overwrite an unrelated managed auth file" do
    write_secure_auth(File.join(source_home, "auth.json"))
    managed_auth = write_secure_auth(File.join(managed_home, "auth.json"), "managed-login")

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("managed_auth_occupied")
    expect(File.symlink?(managed_auth)).to be false
    expect(File.read(managed_auth)).to eq("managed-login")
  end

  it "uses an independent login on Windows" do
    write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home(platform: "x64-mingw32").prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("unsupported_platform")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "does not copy credentials when symlink creation fails" do
    write_secure_auth(File.join(source_home, "auth.json"))
    failing_symlink = lambda do |_source, _destination|
      raise NotImplementedError, "symlinks unavailable"
    end

    result = build_home(symlink_creator: failing_symlink).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("symlink_failed")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "keeps a matching link created concurrently instead of deleting it" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))
    racing_symlink = lambda do |source, destination|
      File.symlink(source, destination)
      raise Errno::EEXIST, destination
    end

    result = build_home(symlink_creator: racing_symlink).prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(result.auth_reused).to be(true)
    expect(File.symlink?(managed_auth)).to be(true)
    expect(File.realpath(managed_auth)).to eq(File.realpath(source_auth))
  end
end

RSpec.describe "Codex ACP launcher" do
  let(:tmpdir) { Dir.mktmpdir("clacky-codex-launcher") }
  let(:codex_home) { File.join(tmpdir, "codex-home") }
  let(:missing) { File.join(tmpdir, "missing") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def launcher_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "launcher.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex launcher at #{path}"
    require path
    Clacky::DefaultExtensions::Codex::Launcher
  end

  def write_executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, path)
    path
  end

  def build_launcher(**options)
    if options[:explicit_path] && !options.key?(:path)
      node_dir = File.join(tmpdir, "explicit-node")
      node = write_executable(File.join(node_dir, "node"))
      previous_probe = options[:version_probe]
      options[:path] = node_dir
      options[:version_probe] = lambda do |path|
        path == node ? "v20.11.1" : previous_probe&.call(path)
      end
    end
    launcher_class.new(
      **{
        codex_home: codex_home,
        packaged_node: missing,
        packaged_entrypoint: missing,
        path: "",
      base_env: {},
        adapter_digest: ->(_path) { launcher_class::ADAPTER_SOURCE_SHA256 },
        codex_package_probe: ->(_path) { launcher_class::CODEX_VERSION }
      }.merge(options)
    )
  end

  it "prefers a verified explicit executable" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    result = build_launcher(explicit_path: explicit).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:explicit)
    expect(result.argv).to eq([
      File.join(tmpdir, "explicit-node", "node"),
      launcher_class::ADAPTER_BOOTSTRAP,
      launcher_class::BOOTSTRAP_RUN_ARG,
      File.realpath(explicit)
    ])
  end

  it "rejects an invalid explicit executable instead of silently falling back" do
    result = build_launcher(explicit_path: File.join(tmpdir, "not-executable")).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("invalid_explicit_path")
    expect(result.message).to match(/executable/i)
  end

  it "rejects an explicit adapter whose published source digest does not match" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    result = build_launcher(
      explicit_path: explicit,
      adapter_digest: ->(_path) { "0" * 64 }
    ).resolve

    expect(result.available?).to be(false)
    expect(result.error_code).to eq("unverified_explicit_path")
    expect(result.message).to match(/SHA-256/)
  end

  it "uses a packaged managed Node and exact adapter entry point before PATH" do
    node = write_executable(File.join(tmpdir, "package", "node", "bin", "node"))
    entrypoint = File.join(tmpdir, "package", "node_modules", "@agentclientprotocol", "codex-acp", "dist", "index.js")
    FileUtils.mkdir_p(File.dirname(entrypoint))
    File.write(entrypoint, "// packaged adapter")
    path_dir = File.join(tmpdir, "path-bin")
    write_executable(File.join(path_dir, "codex-acp"))

    result = build_launcher(
      packaged_node: node,
      packaged_entrypoint: entrypoint,
      path: path_dir,
      version_probe: ->(_path) { "codex-acp 1.11.0" }
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:packaged)
    expect(result.argv).to eq([
      File.expand_path(node),
      launcher_class::ADAPTER_BOOTSTRAP,
      launcher_class::BOOTSTRAP_RUN_ARG,
      File.expand_path(entrypoint)
    ])
    expect(result.version).to eq("1.11.0")
  end

  it "does not automatically trust an installed codex-acp even when versions match" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))
    node = write_executable(File.join(bin_dir, "node"))
    npx = write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: lambda do |path|
        path == executable ? "codex-acp 1.11.0" : "v20.11.1"
      end
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:npx)
    expect(result.argv).to eq([
      File.expand_path(npx),
      "-y",
      "--package=@agentclientprotocol/codex-acp@1.11.0",
      "--package=@openai/codex@0.153.4",
      "--",
      File.expand_path(node),
      launcher_class::ADAPTER_BOOTSTRAP,
      launcher_class::BOOTSTRAP_RUN_ARG
    ])
    expect(result.version).to eq("1.11.0")
  end

  it "rejects an implicitly discovered installed adapter without a package-managed fallback" do
    package_root = File.join(tmpdir, "lib", "node_modules", "@agentclientprotocol", "codex-acp")
    entrypoint = write_executable(File.join(package_root, "dist", "index.js"))
    File.write(
      File.join(package_root, "package.json"),
      JSON.generate("name" => "@agentclientprotocol/codex-acp", "version" => "1.11.0")
    )
    bin_dir = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(entrypoint, File.join(bin_dir, "codex-acp"))
    node = write_executable(File.join(bin_dir, "node"))
    File.write(node, "#!/bin/sh\nprintf 'v20.11.1\\n'\n")

    result = build_launcher(path: bin_dir).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("untrusted_installed_codex_acp")
    expect(result.message).to match(/not automatically trusted/i)
    expect(result.message).to match(/operator-trusted/i)
    expect(result.message).not_to match(/audited/i)
  end

  it "skips an installed adapter with a drifted Codex dependency and uses the double-pinned fallback" do
    bin_dir = File.join(tmpdir, "bin")
    installed = write_executable(File.join(bin_dir, "codex-acp"))
    node = write_executable(File.join(bin_dir, "node"))
    npx = write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: lambda do |path|
        path == installed ? "codex-acp 1.11.0" : "v20.11.1"
      end,
      codex_package_probe: ->(_path) { "0.154.0" }
    ).resolve

    expect(result.available?).to be(true)
    expect(result.source).to eq(:npx)
    expect(result.argv).to eq([
      File.expand_path(npx),
      "-y",
      "--package=@agentclientprotocol/codex-acp@1.11.0",
      "--package=@openai/codex@0.153.4",
      "--",
      File.expand_path(node),
      launcher_class::ADAPTER_BOOTSTRAP,
      launcher_class::BOOTSTRAP_RUN_ARG
    ])
  end

  it "reports an incompatible installed adapter when no safe fallback exists" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == executable ? "codex-acp 1.10.0" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_codex_acp")
    expect(result.message).to include("1.11.0")
  end

  it "rejects a prerelease that only shares the pinned version prefix" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == executable ? "codex-acp 1.11.0-beta.1" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_codex_acp")
  end

  it "falls back to a pinned npx package only with Node.js 20 or newer" do
    bin_dir = File.join(tmpdir, "bin")
    node = write_executable(File.join(bin_dir, "node"))
    npx = write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == node ? "v20.11.1" : nil }
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:npx)
    expect(result.argv).to eq([
      File.expand_path(npx),
      "-y",
      "--package=@agentclientprotocol/codex-acp@1.11.0",
      "--package=@openai/codex@0.153.4",
      "--",
      File.expand_path(node),
      launcher_class::ADAPTER_BOOTSTRAP,
      launcher_class::BOOTSTRAP_RUN_ARG
    ])
    expect(result.cwd).to eq(File.expand_path(codex_home))
    expect(result.env).to include(
      "NPM_CONFIG_USERCONFIG" => File::NULL,
      "NPM_CONFIG_REGISTRY" => "https://registry.npmjs.org/",
      "NPM_CONFIG_IGNORE_SCRIPTS" => "true"
    )
  end

  it "ships a checksum-verified bootstrap that disables project-local Codex config" do
    node = RbConfig.ruby.sub(/ruby\z/, "node")
    node = `command -v node`.strip unless File.executable?(node)
    skip "Node.js is required for the adapter bootstrap test" unless File.executable?(node)

    marker = "projects: Object.fromEntries(sessionRoots.map((root) => [root, {\n" \
             "        trust_level: \"trusted\"\n" \
             "      }]))"
    source = "before\n#{marker}\nafter\n"
    digest = Digest::SHA256.hexdigest(source)
    script = <<~JS
      import { pathToFileURL } from "node:url";
      const module = await import(pathToFileURL(process.argv[1]).href);
      const source = process.argv[2];
      process.stdout.write(module.patchAdapterSource(source, process.argv[3]));
    JS

    stdout, stderr, status = Open3.capture3(
      node,
      "--input-type=module",
      "-e",
      script,
      launcher_class::ADAPTER_BOOTSTRAP,
      source,
      digest
    )

    expect(status).to be_success, stderr
    expect(stdout).to include('trust_level: "untrusted"')
    expect(stdout).not_to include('trust_level: "trusted"')
    expect(launcher_class::ADAPTER_SOURCE_SHA256)
      .to eq("3527bdaf90a219175c742576963e6d9e943e4ea5fbdbc3e04e7f57f9a9e11343")
    expect(File.read(launcher_class::ADAPTER_BOOTSTRAP))
      .to include(launcher_class::ADAPTER_SOURCE_SHA256)
  end

  it "accepts only the exact pinned Codex package beside the adapter" do
    node = RbConfig.ruby.sub(/ruby\z/, "node")
    node = `command -v node`.strip unless File.executable?(node)
    skip "Node.js is required for the adapter bootstrap test" unless File.executable?(node)

    adapter_root = File.join(tmpdir, "node_modules", "@agentclientprotocol", "codex-acp")
    adapter = File.join(adapter_root, "dist", "index.js")
    codex_root = File.join(tmpdir, "node_modules", "@openai", "codex")
    codex_bin = File.join(codex_root, "bin", "codex.js")
    FileUtils.mkdir_p(File.dirname(adapter))
    FileUtils.mkdir_p(File.dirname(codex_bin))
    File.write(adapter, "// adapter")
    File.write(codex_bin, "#!/usr/bin/env node\n")
    File.write(
      File.join(codex_root, "package.json"),
      JSON.generate("name" => "@openai/codex", "version" => "0.153.4")
    )
    script = <<~JS
      import { pathToFileURL } from "node:url";
      const module = await import(pathToFileURL(process.argv[1]).href);
      process.stdout.write(module.resolveVerifiedCodex(process.argv[2], process.argv[3]));
    JS

    stdout, stderr, status = Open3.capture3(
      node,
      "--input-type=module",
      "-e",
      script,
      launcher_class::ADAPTER_BOOTSTRAP,
      adapter,
      launcher_class::CODEX_VERSION
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq(File.realpath(codex_bin))

    File.write(
      File.join(codex_root, "package.json"),
      JSON.generate("name" => "@openai/codex", "version" => "0.153.5")
    )
    _stdout, mismatch_stderr, mismatch_status = Open3.capture3(
      node,
      "--input-type=module",
      "-e",
      script,
      launcher_class::ADAPTER_BOOTSTRAP,
      adapter,
      launcher_class::CODEX_VERSION
    )

    expect(mismatch_status).not_to be_success
    expect(mismatch_stderr).to match(/expected.*0\.153\.4.*0\.153\.5/i)
  end

  it "reports an actionable error for an incompatible Node.js fallback" do
    bin_dir = File.join(tmpdir, "bin")
    node = write_executable(File.join(bin_dir, "node"))
    write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == node ? "v18.20.0" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_node")
    expect(result.message).to match(/Node\.js 20/)
  end

  it "reports missing launch dependencies without invoking an unpinned package" do
    result = build_launcher.resolve

    expect(result.available?).to be false
    expect(result.argv).to be_nil
    expect(result.error_code).to eq("missing_dependencies")
    expect(result.message).to include("Node.js 20+")
    expect(result.message).to include("CLACKY_CODEX_ACP_PATH")
    expect(result.message).not_to match(/Install codex-acp/i)
  end

  it "reports the prototype as unavailable on Windows until process-tree cleanup is supported" do
    result = build_launcher(platform: "x64-mingw32").resolve

    expect(result.available?).to be(false)
    expect(result.error_code).to eq("unsupported_platform")
  end

  it "sanitizes credentials and fixes the managed runtime environment" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))
    codex = write_executable(File.join(tmpdir, "codex"))
    result = build_launcher(
      explicit_path: explicit,
      codex_path: codex,
      base_env: {
        "PATH" => "/safe/bin",
        "OPENAI_API_KEY" => "openai-secret",
        "OPENAI_BASE_URL" => "https://unsafe.example",
        "CODEX_API_KEY" => "codex-secret",
        "CODEX_ACCESS_TOKEN" => "access-secret",
        "CODEX_HOME" => "/unmanaged",
        "CODEX_PATH" => "/unverified/codex",
        "CODEX_CONFIG" => "unsafe-config",
        "CODEX_SQLITE_HOME" => "/unmanaged-state",
        "DEFAULT_AUTH_REQUEST" => "unsafe-auth",
        "MODEL_PROVIDER" => "unsafe-provider",
        "APP_SERVER_LOGS" => "/unmanaged-logs",
        "DISABLE_MCP_CONFIG_FILTERING" => "true",
        "INITIAL_AGENT_MODE" => "agent-full-access",
        "NPM_TOKEN" => "npm-secret",
        "AWS_SECRET_ACCESS_KEY" => "aws-secret",
        "GITHUB_TOKEN" => "github-secret",
        "SSH_AUTH_SOCK" => "/private/ssh-agent.sock",
        "NODE_OPTIONS" => "--require /private/inject.js",
        "HTTP_PROXY" => "http://proxy-user:proxy-password@proxy.example",
        "HTTPS_PROXY" => "http://proxy-user:proxy-password@proxy.example",
        "ALL_PROXY" => "socks5://proxy-user:proxy-password@proxy.example",
        "NO_PROXY" => "localhost",
        "http_proxy" => "http://lower-user:lower-password@proxy.example",
        "https_proxy" => "http://lower-user:lower-password@proxy.example",
        "all_proxy" => "socks5://lower-user:lower-password@proxy.example",
        "no_proxy" => "localhost",
        "DISPLAY" => ":0",
        "WAYLAND_DISPLAY" => "wayland-0",
        "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/run/user/1000/bus",
        "XDG_RUNTIME_DIR" => "/run/user/1000"
      }
    ).resolve

    expect(result.env).to include(
      "PATH" => "/safe/bin",
      "CODEX_HOME" => File.expand_path(codex_home),
      "CODEX_PATH" => File.expand_path(codex),
      "INITIAL_AGENT_MODE" => "read-only",
      "DISPLAY" => ":0",
      "WAYLAND_DISPLAY" => "wayland-0",
      "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/run/user/1000/bus",
      "XDG_RUNTIME_DIR" => "/run/user/1000"
    )
    protected_config = JSON.parse(result.env.fetch("CODEX_CONFIG"))
    profile = protected_config.fetch("default_permissions")
    expect(profile).to start_with("openclacky-protected-")
    expect(protected_config).to include("allow_login_shell" => false)
    expect(protected_config.dig(
      "permissions", profile, "filesystem",
      File.join(File.expand_path(codex_home), "auth.json")
    )).to eq("deny")
    expect(protected_config.dig("shell_environment_policy", "exclude")).to include(
      "CODEX_HOME", "CODEX_CONFIG",
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "all_proxy", "no_proxy",
      "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
      "XDG_RUNTIME_DIR"
    )
    expect(result.env).to include(
      "HTTP_PROXY" => "http://proxy-user:proxy-password@proxy.example",
      "https_proxy" => "http://lower-user:lower-password@proxy.example"
    )
    expect(result.env.keys).not_to include(
      "OPENAI_API_KEY",
      "OPENAI_BASE_URL",
      "CODEX_API_KEY",
      "CODEX_ACCESS_TOKEN",
      "CODEX_SQLITE_HOME",
      "DEFAULT_AUTH_REQUEST",
      "MODEL_PROVIDER",
      "APP_SERVER_LOGS",
      "DISABLE_MCP_CONFIG_FILTERING",
      "NPM_TOKEN",
      "AWS_SECRET_ACCESS_KEY",
      "GITHUB_TOKEN",
      "SSH_AUTH_SOCK",
      "NODE_OPTIONS"
    )
    expect(result.env.values).not_to include("/unverified/codex", "agent-full-access")
  end

  it "forces an adapter-level permission profile that hides every auth path" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))
    source_auth = File.join(tmpdir, "source", "auth.json")
    result = build_launcher(
      explicit_path: explicit,
      protected_auth_paths: [source_auth, source_auth, ""]
    ).resolve

    config = JSON.parse(result.env.fetch("CODEX_CONFIG"))
    profile = config.fetch("default_permissions")
    filesystem = config.dig("permissions", profile, "filesystem")

    expect(filesystem).to eq(
      File.join(File.expand_path(codex_home), "auth.json") => "deny",
      File.expand_path(source_auth) => "deny"
    )
    expect(config.dig("permissions", profile, "extends"))
      .to eq(":workspace")
  end

  it "uses an unpredictable permission profile name per launcher" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    first = build_launcher(explicit_path: explicit).resolve
    second = build_launcher(explicit_path: explicit).resolve
    first_profile = JSON.parse(first.env.fetch("CODEX_CONFIG"))
      .fetch("default_permissions")
    second_profile = JSON.parse(second.env.fetch("CODEX_CONFIG"))
      .fetch("default_permissions")

    expect(first_profile).to start_with("openclacky-protected-")
    expect(second_profile).to start_with("openclacky-protected-")
    expect(first_profile).not_to eq(second_profile)
  end

  it "does not propagate an unverified CODEX_PATH" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    result = build_launcher(
      explicit_path: explicit,
      base_env: { "CODEX_PATH" => "/unverified/codex" }
    ).resolve

    expect(result.env["CODEX_PATH"]).to be_nil
  end

  it "does not override the adapter's bundled Codex executable from PATH" do
    bin_dir = File.join(tmpdir, "bin")
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))
    codex = write_executable(File.join(bin_dir, "codex"))
    node = write_executable(File.join(bin_dir, "node"))

    result = build_launcher(
      explicit_path: explicit,
      path: bin_dir,
      version_probe: ->(path) { path == node ? "v20.11.1" : nil }
    ).resolve

    expect(result.available?).to be(true)
    expect(File).to exist(codex)
    expect(result.env["CODEX_PATH"]).to be_nil
  end

  it "actually removes parent credentials and adapter overrides from the child process" do
    fake_agent = File.expand_path("../support/fake_acp_agent.rb", __dir__)
    transport = nil

    ClimateControl.modify(
      "OPENAI_API_KEY" => "parent-openai-secret",
      "CODEX_PATH" => "/parent/unverified-codex",
      "DEFAULT_AUTH_REQUEST" => "parent-unsafe-auth"
    ) do
      launch = build_launcher(
        explicit_path: RbConfig.ruby,
        base_env: ENV.to_h
      ).resolve
      events = Queue.new
      transport = Clacky::Acp::ProcessTransport.new(
        name: "codex-env-probe",
        argv: [RbConfig.ruby, fake_agent],
        env: launch.env,
        max_message_bytes: 4096,
        stderr_bytes: 1024
      )
      transport.on_message { |message| events << message }
      transport.start
      transport.send_message(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "fake/inspect",
        "params" => {
          "env_keys" => %w[OPENAI_API_KEY CODEX_PATH DEFAULT_AUTH_REQUEST CODEX_HOME]
        }
      )
      response = Timeout.timeout(3) do
        loop do
          message = events.pop
          break message if message["id"] == 1
        end
      end

      expect(response.dig("result", "env")).to eq(
        "OPENAI_API_KEY" => nil,
        "CODEX_PATH" => nil,
        "DEFAULT_AUTH_REQUEST" => nil,
        "CODEX_HOME" => File.expand_path(codex_home)
      )
    end
  ensure
    transport&.stop
  end
end

RSpec.describe "Codex extension status shell" do
  def codex_api_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "api",
      "handler.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex API handler at #{path}"
    require path
    CodexExt
  end

  it "returns only safe readiness metadata" do
    home_result = OpenStruct.new(
      managed_home: "/private/home",
      auth_reused: true,
      auth_reason: "reused",
      auth_contents: "refresh-token-secret"
    )
    launcher_result = OpenStruct.new(
      available?: true,
      argv: ["npx", "secret-argument"],
      env: { "OPENAI_API_KEY" => "api-key-secret" },
      source: :npx,
      version: "1.11.0",
      error_code: nil,
      message: nil
    )

    payload = codex_api_class.status_payload(
      home_result: home_result,
      launcher_result: launcher_result
    )
    serialized = JSON.generate(payload)

    expect(payload).to eq(
      available: true,
      status: "ready",
      authenticated: nil,
      auth_reused: true,
      auth_reason: "reused",
      launcher: "npx",
      version: "1.11.0"
    )
    expect(serialized).not_to include(
      "refresh-token-secret",
      "api-key-secret",
      "secret-argument",
      "/private/home"
    )
  end

  it "keeps GET status passive and uses explicit POSTs for connection and discovery" do
    klass = codex_api_class
    runtime = Clacky::DefaultExtensions::Codex::Runtime
    allow(runtime).to receive(:passive_status).and_return(
      available: nil, status: "idle", authenticated: nil
    )
    allow(runtime).to receive(:status).and_return(
      available: true, status: "connected", authenticated: true
    )
    allow(runtime).to receive(:authenticate_async).and_return(
      ok: true, started: true, status: "authenticating"
    )
    allow(runtime).to receive(:discover_models).and_return(
      ok: true,
      status: "connected",
      authenticated: true,
      default_model: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"]
    )

    status_route = klass.routes.find { |route| route.method == :get && route.pattern == "/status" }
    connect_route = klass.routes.find { |route| route.method == :post && route.pattern == "/connect" }
    auth_route = klass.routes.find { |route| route.method == :post && route.pattern == "/authenticate" }
    discover_route = klass.routes.find { |route| route.method == :post && route.pattern == "/discover" }
    expect(status_route).not_to be_nil
    expect(connect_route).not_to be_nil
    expect(auth_route).not_to be_nil
    expect(discover_route).not_to be_nil
    expect(status_route.options).to include(timeout: 10, same_origin: true)
    expect(connect_route.options).to include(same_origin: true)
    expect(auth_route.options).to include(same_origin: true)
    expect(discover_route.options).to include(same_origin: true)
    expect(connect_route.options[:timeout]).to eq(310)
    expect(auth_route.options[:timeout]).to eq(310)
    expect(discover_route.options[:timeout]).to eq(310)

    status_handler = klass.new(req: nil, res: nil, route: status_route, params: {}, http_server: nil)
    expect { status_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "status" => "idle", "authenticated" => nil
      )
    end

    connect_handler = klass.new(req: nil, res: nil, route: connect_route, params: {}, http_server: nil)
    expect { connect_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "status" => "connected", "authenticated" => true
      )
    end

    auth_handler = klass.new(req: nil, res: nil, route: auth_route, params: {}, http_server: nil)
    expect { auth_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(202)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true, "started" => true, "status" => "authenticating"
      )
    end

    discover_handler = klass.new(
      req: nil, res: nil, route: discover_route, params: {}, http_server: nil
    )
    expect { discover_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true,
        "default_model" => "gpt-5.6-sol",
        "models" => ["gpt-5.6-sol"]
      )
    end
  end
end
