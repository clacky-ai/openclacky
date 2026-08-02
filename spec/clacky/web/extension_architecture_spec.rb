# frozen_string_literal: true

# Static guardrails for the WebUI extension architecture (core/ext.js) and the
# store/view layering convention (features/<feature>/{store,view}.js).
#
# These are source-level checks, not behavioural tests: they encode the
# "constitution" of the extension system so a future refactor can't silently
# break the three survival promises — isolation, escape hatch, error boundary —
# or blur the store/view split that keeps pure mode safe.

RSpec.describe "WebUI extension architecture" do
  let(:web_dir)  { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:ext_js)   { File.read(File.join(web_dir, "core", "ext.js")) }
  let(:features) { Dir[File.join(web_dir, "features", "*")].select { |p| File.directory?(p) } }

  # ─── core/ext.js contract ──────────────────────────────────────────────────

  describe "core/ext.js registry contract" do
    it "exists" do
      expect(File).to exist(File.join(web_dir, "core", "ext.js"))
    end

    it "detects pure mode from the ?pure=true query param" do
      expect(ext_js).to match(/get\(["']pure["']\)\s*===\s*["']true["']/)
    end

    it "exposes the full extension API surface (register/subscribe/ui.mount)" do
      expect(ext_js).to include("register(")
      expect(ext_js).to include("subscribe(")
      expect(ext_js).to include("mount(")
      expect(ext_js).to include("renderSlot(")
    end

    it "makes register/subscribe/mount no-ops under pure mode" do
      # Each public registration entry point must bail out when PURE is on, so
      # extension code can never affect the page in the escape-hatch mode.
      %w[register subscribe mount].each do |fn|
        body = ext_js[/\b#{fn}\([^)]*\)\s*\{(.+?)\n  \}/m, 1]
        expect(body).not_to be_nil, "could not locate #{fn}() body in ext.js"
        expect(body).to match(/if\s*\(\s*PURE/),
          "#{fn}() must short-circuit on PURE (pure-mode no-op guarantee)"
      end
    end

    it "wraps extension callbacks in a guard (error boundary)" do
      expect(ext_js).to match(/function _guard\(/)
      expect(ext_js).to match(/try\s*\{/)
      expect(ext_js).to match(/catch\s*\(/)
    end

    it "degrades a crashed slot to a marked placeholder, not a thrown error" do
      expect(ext_js).to include('data-ext-status')
      expect(ext_js).to include('"crashed"')
    end

    it "does not call into host modules by name (extensions reach host only via the registry)" do
      # ext.js is the boundary; it must not hard-depend on feature globals.
      %w[Sessions Skills Tasks Settings Router].each do |host_global|
        expect(ext_js).not_to match(/\b#{host_global}\./),
          "ext.js must not reference host module #{host_global} directly"
      end
    end

    it "exposes host-owned homepage candidate operations" do
      expect(ext_js).to include("registerHomepage(")
      expect(ext_js).to include("homepageCandidates(")
      expect(ext_js).to include("selectHomepage(")
      expect(ext_js).to include("resolveHomepage(")
    end

    it "only accepts a registered workspace as a homepage candidate" do
      body = ext_js[/registerHomepage\(workspaceId, definition.*?\n    \},/m]
      expect(body).not_to be_nil, "could not locate registerHomepage() body in ext.js"
      expect(body).to include("_workspaces[workspaceId]")
    end

    it "does not navigate while registering a homepage candidate" do
      body = ext_js[/registerHomepage\(workspaceId, definition.*?\n    \},/m]
      expect(body).not_to be_nil, "could not locate registerHomepage() body in ext.js"
      expect(body).not_to include("location.hash")
      expect(body).not_to include("clacky:ext:navigate")
    end
  end

  # ─── store/view layering discipline ─────────────────────────────────────────

  describe "store/view layering" do
    it "every feature directory ships both a store.js and a view.js" do
      features.each do |dir|
        expect(File).to exist(File.join(dir, "store.js")),
          "#{File.basename(dir)} feature missing store.js"
        expect(File).to exist(File.join(dir, "view.js")),
          "#{File.basename(dir)} feature missing view.js"
      end
    end

    it "store.js never touches the DOM (data/state/network only)" do
      dom_apis = /\b(document\.(getElementById|querySelector|querySelectorAll|createElement|addEventListener)|\.innerHTML\b|\.appendChild\b|\.insertAdjacent)/
      features.each do |dir|
        store = File.join(dir, "store.js")
        next unless File.exist?(store)

        offenders = File.read(store).each_line.with_index(1).select { |line, _| line.match?(dom_apis) }
        expect(offenders).to be_empty,
          "#{File.basename(dir)}/store.js touches the DOM (store must stay render-free):\n" \
          "#{offenders.map { |l, n| "  L#{n}: #{l.strip}" }.join("\n")}"
      end
    end

    it "view.js never fetches core data directly (must go through the store)" do
      # The view reacts to store events and calls store actions; it must not own
      # the network. Uploads via /api/upload are a pure-UI affordance and allowed.
      features.each do |dir|
        view = File.join(dir, "view.js")
        next unless File.exist?(view)

        offenders = File.read(view).each_line.with_index(1).select do |line, _|
          line.match?(/\bfetch\(/) && !line.include?("/api/upload")
        end
        expect(offenders).to be_empty,
          "#{File.basename(dir)}/view.js fetches data directly (route it through the store):\n" \
          "#{offenders.map { |l, n| "  L#{n}: #{l.strip}" }.join("\n")}"
      end
    end

    it "core view.js does NOT depend on Clacky.ext.subscribe (silenced under pure mode)" do
      # The core panel must keep rendering in pure mode, so it must use the
      # store's always-live internal bus (Store.on), never the extension bus
      # which is intentionally a no-op when ?pure=true.
      features.each do |dir|
        view = File.join(dir, "view.js")
        next unless File.exist?(view)

        expect(File.read(view)).not_to match(/Clacky\.ext\.subscribe/),
          "#{File.basename(dir)}/view.js subscribes via Clacky.ext (would break in pure mode); " \
          "use the store's internal bus instead"
      end
    end

    it "store.js mirrors changes onto the extension bus (Clacky.ext.emit)" do
      # Stores broadcast to extensions so they can observe core data changes.
      features.each do |dir|
        store = File.join(dir, "store.js")
        next unless File.exist?(store)

        expect(File.read(store)).to match(/Clacky\.ext\.emit/),
          "#{File.basename(dir)}/store.js should mirror events to the extension bus"
      end
    end
  end

  # ─── index.html wiring ──────────────────────────────────────────────────────

  describe "index.html extension wiring" do
    let(:index) { File.read(File.join(web_dir, "index.html")) }

    it "loads core/ext.js before any feature/extension code" do
      ext_pos = index.index("/core/ext.js")
      app_pos = index.index("/app.js")
      expect(ext_pos).not_to be_nil
      expect(app_pos).not_to be_nil
      expect(ext_pos).to be < app_pos
    end

    it "carries the {{EXT_SCRIPTS}} injection point in the script-loading region" do
      expect(index).to include("{{EXT_SCRIPTS}}")
    end

    it "loads each feature's store.js before its view.js" do
      features.each do |dir|
        name = File.basename(dir)
        store_pos = index.index("features/#{name}/store.js")
        view_pos  = index.index("features/#{name}/view.js")
        next if store_pos.nil? || view_pos.nil?

        expect(store_pos).to be < view_pos,
          "index.html must load features/#{name}/store.js before view.js"
      end
    end

    it "declares the named UI slots extensions mount into" do
      # The host opens these injection points; losing one silently strands every
      # extension that targets it. Both "new place" and "enhance existing" slots.
      %w[
        header.left header.right sidebar.nav sidebar.footer main.workspace
        settings.tabs settings.body
      ].each do |slot|
        expect(index).to match(/data-slot=["']#{Regexp.escape(slot)}["']/),
          "index.html must declare the #{slot} extension slot"
      end
    end

    it "renders every declared slot generically (no slot left unmounted)" do
      # A single sweep over [data-slot] mounts all of them, so adding a slot in
      # markup is enough — no per-slot wiring to forget.
      expect(index).to match(/querySelectorAll\(\s*["']\[data-slot\]["']\s*\)/)
      expect(index).to include("Clacky.ext.renderSlot(")
    end
  end

  # ─── Clacky.* host facades — the single public API surface ─────────────────

  describe "Clacky.* namespace exposes core host facades" do
    # Extensions and AI-generated code should reach host services through the
    # single `Clacky` namespace (already the escape hatch on window). Each
    # facade must be assigned back onto `Clacky` next to its IIFE, so both the
    # legacy bare form (`Sessions.on`) and the recommended form
    # (`Clacky.Sessions.on` / `window.Clacky.Sessions.on`) work identically.
    {
      "Sessions"       => "sessions.js",
      "Skills"         => "features/skills/store.js",
      "SkillAC"        => "skills.js",
      "Router"         => "app.js",
      "Modal"          => "app.js",
      "I18n"           => "i18n.js",
      "Notify"         => "components/notify.js",
      "Auth"           => "auth.js",
      "WS"             => "ws.js",
      "Workspace"      => "features/workspace/store.js",
      "WorkspaceStore" => "features/workspace/store.js",
      "Backup"         => "features/backup/store.js",
    }.each do |name, rel|
      it "exposes Clacky.#{name} in #{rel}" do
        src = File.read(File.join(web_dir, rel))
        expect(src).to include("Clacky.#{name} = "),
          "#{rel} must assign `Clacky.#{name} = #{name};` so extensions can reach it via the Clacky namespace"
      end
    end
  end

  describe "extension development skill" do
    let(:skill) do
      File.read(File.expand_path("../../../lib/clacky/default_extensions/ext-studio/skills/ext-develop/SKILL.md", __dir__))
    end

    it "documents homepage candidate registration and conflict rules" do
      expect(skill).to include("registerHomepage")
      expect(skill).to include("exactly one")
      expect(skill).to include("must not rewrite `/#new`")
    end
  end
end
