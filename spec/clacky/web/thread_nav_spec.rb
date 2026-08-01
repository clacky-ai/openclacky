# frozen_string_literal: true

# Source-level guardrails for the in-thread navigation rail (thread-nav.js).
#
# These checks encode the structural contract of the navigation rail so that a
# future refactor cannot silently break the core promises the feature makes:
#
#   1. **Observation** — the rail stays in sync with the DOM via MutationObserver,
#      not a one-time scan.
#   2. **Navigation** — markers are clickable and scroll the target into view.
#   3. **Hover preview** — a CSS-driven preview card shows context per marker.
#   4. **Active tracking** — the marker for the currently-visible turn is highlighted.
#   5. **Graceful degradation** — the rail must not throw if the DOM is empty.

RSpec.describe "Thread navigation rail" do
  let(:web_dir)     { File.expand_path("../../../lib/clacky/web", __dir__) }
  let(:js_path)     { File.join(web_dir, "thread-nav.js") }
  let(:js_source)   { File.read(js_path) }
  let(:html_source) { File.read(File.join(web_dir, "index.html")) }
  let(:css_source)  { File.read(File.join(web_dir, "app.css")) }

  # ─── File presence & wiring ────────────────────────────────────────────────

  describe "file presence and wiring" do
    it "thread-nav.js exists" do
      expect(File).to exist(js_path)
    end

    it "index.html loads thread-nav.js" do
      expect(html_source).to include('thread-nav.js'),
        "index.html must load thread-nav.js via a <script> tag"
    end

    it "index.html contains the nav container element" do
      expect(html_source).to match(%r{<nav[^>]*id=["']thread-nav["']}).
        and(match(/thread-nav/))
    end
  end

  # ─── MutationObserver contract ─────────────────────────────────────────────

  describe "MutationObserver-based observation" do
    it "creates a MutationObserver instance" do
      expect(js_source).to match(/new\s+MutationObserver/)
    end

    it "observes the messages container for child-list changes" do
      expect(js_source).to match(/\.observe\(/)
      expect(js_source).to match(/childList/)
    end

    it "disconnects the observer to avoid memory leaks" do
      expect(js_source).to match(/\.disconnect\(/)
    end
  end

  # ─── Rail construction ─────────────────────────────────────────────────────

  describe "rail construction" do
    it "targets the nav container by id" do
      expect(js_source).to match(/getElementById\(\s*["']thread-nav["']|["']thread-nav["']/)
    end

    it "identifies user turns via .msg-user-wrap elements" do
      expect(js_source).to include("msg-user-wrap"),
        "must scan for .msg-user-wrap to identify conversation turns"
    end

    it "creates marker elements dynamically via createElement" do
      expect(js_source).to match(/createElement/)
    end

    it "assigns the thread-nav-item class to markers" do
      expect(js_source).to include("thread-nav-item")
    end
  end

  # ─── Click-to-scroll navigation ────────────────────────────────────────────

  describe "click-to-scroll navigation" do
    it "attaches click handlers to marker items" do
      expect(js_source).to match(/addEventListener\(\s*["']click["']/)
    end

    it "scrolls the target message into view on click" do
      expect(js_source).to match(/scrollIntoView|\.scrollTop\s*=|\.scrollTo\(/)
    end
  end

  # ─── Hover preview (CSS-driven) ────────────────────────────────────────────

  describe "hover preview card" do
    it "creates a preview card element in JS" do
      expect(js_source).to include("thread-nav-card")
    end

    it "defines the card as a child of the marker (for CSS :hover)" do
      expect(js_source).to match(/item\.appendChild|item\.insertAdjacent|card/)
    end

    it "CSS shows the card on marker hover" do
      expect(css_source).to match(/\.thread-nav-item:hover\s+\.thread-nav-card|\.thread-nav-item:hover\s*\{/)
    end
  end

  # ─── Active marker tracking ────────────────────────────────────────────────

  describe "active marker tracking" do
    it "tracks scroll position to determine the active turn" do
      expect(js_source).to match(/scroll|getBoundingClientRect/)
    end

    it "toggles an active class on the current marker" do
      expect(js_source).to match(/classList\.toggle\(|classList\.add\(/)
      expect(js_source).to include("thread-nav-active")
    end
  end

  # ─── Graceful degradation ──────────────────────────────────────────────────

  describe "graceful degradation" do
    it "guards against a missing nav element before operating" do
      expect(js_source).to match(/if\s*\(\s*!.*\)\s*return|return\s+null|return\s*;?\s*\n/),
        "thread-nav.js must early-return when required elements are absent"
    end

    it "handles an empty conversation (no user wraps) without throwing" do
      expect(js_source).to match(/\.length\s*===\s*0|\.length\s*<\s*1|thread-nav-empty|!.*wraps|!.*length/),
        "must detect and handle the empty-rail case"
    end
  end

  # ─── CSS styling contract ──────────────────────────────────────────────────

  describe "CSS styling contract" do
    it "defines the rail container style" do
      expect(css_source).to match(/\.thread-nav\s*\{/)
    end

    it "defines the dash marker style" do
      expect(css_source).to match(/\.thread-nav-dash\s*\{/)
    end

    it "defines the preview card style" do
      expect(css_source).to match(/\.thread-nav-card\s*\{/)
    end

    it "defines the active marker style" do
      expect(css_source).to match(/\.thread-nav-active|\.thread-nav-item\.active/)
    end

    it "reserves left padding on the chat container for the rail" do
      expect(css_source).to include("22px"),
        "chat-messages-scroll must reserve 22px left padding for the rail"
    end
  end
end
