"use strict";

// Regression harness for slash-command detection in the composer.
//
// Typing a filesystem path like "/Users/alice/Download" used to be treated as a
// slash command: the palette opened, matched nothing, and then swallowed Enter
// because _activeIndex was 0 while _items was empty — the message could not be
// sent at all. The client's notion of "this is a command" must match the
// backend's parse_skill_command, which rejects a path-shaped first token.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = name => path.resolve(__dirname, "../../lib/clacky/web", name);

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.style = {};
    this.dataset = {};
    this.attrs = {};
    this.children = [];
    this.handlers = {};
    this.classes = new Set();
    this.textContent = "";
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
      contains: name => this.classes.has(name),
    };
  }
  set className(value) { this.classes = new Set(String(value).split(/\s+/).filter(Boolean)); }
  get className() { return Array.from(this.classes).join(" "); }
  set innerHTML(value) { this._html = value; this.children = []; }
  get innerHTML() { return this._html || ""; }
  get firstChild() { return this.children[0] || null; }
  insertBefore(child, ref) {
    child.parentNode = this;
    const i = this.children.indexOf(ref);
    if (i < 0) this.children.push(child); else this.children.splice(i, 0, child);
  }
  dispatchEvent(event) { if (this.handlers[event.type]) this.handlers[event.type](event); }
  click() { this.clicked = (this.clicked || 0) + 1; }
  setAttribute(key, value) { this.attrs[key] = value; }
  addEventListener(key, fn) { this.handlers[key] = fn; }
  appendChild(child) { child.parentNode = this; this.children.push(child); }
  remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(c => c !== this); }
  querySelector(selector) {
    if (!selector.startsWith(".")) return null;
    const name = selector.slice(1);
    for (const child of this.children) {
      if (child.classes.has(name)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
  querySelectorAll(selector) {
    const name = selector.replace(/^\./, "");
    const out = [];
    for (const child of this.children) {
      if (child.classes.has(name)) out.push(child);
      out.push(...child.querySelectorAll(selector));
    }
    return out;
  }
  focus() {}
  scrollIntoView() {}
}

function loadSkillAC(skills) {
  const nodes = {
    "user-input": new Element("textarea"),
    "skill-autocomplete": new Element(),
    "skill-autocomplete-list": new Element(),
    "btn-slash": new Element("button"),
    "image-file-input": new Element("input"),
    "btn-create-skill": new Element("button"),
    "btn-import-skill": new Element("button"),
  };
  const count = new Element();
  count.className = "skill-ac-count";
  nodes["skill-autocomplete"].appendChild(count);
  const actions = new Element();
  actions.className = "skill-ac-actions";
  nodes["skill-autocomplete"].appendChild(actions);
  nodes["skill-autocomplete"].appendChild(nodes["skill-autocomplete-list"]);
  nodes.actions = actions;
  const mentionOpens = [];

  const store = {};
  const body = new Element("body");
  const context = vm.createContext({
    console,
    document: {
      body,
      createElement: tag => new Element(tag),
      createTextNode: text => Object.assign(new Element("#text"), { nodeType: 3, nodeValue: String(text), textContent: String(text) }),
      getElementById: id => nodes[id] || null,
    },
    localStorage: {
      getItem: key => (key in store ? store[key] : null),
      setItem: (key, value) => { store[key] = String(value); },
    },
    JSON, Date, Promise, String, Object, Array, Math, RegExp,
    setTimeout, clearTimeout,
    $: id => nodes[id] || null,
    escapeHtml: text => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;"),
    Clacky: {},
    I18n: { t: key => key, lang: () => "en" },
    IME: { track: () => ({ isComposing: () => false }) },
    Composer: {
      text: el => el.value || "",
      setText: (el, value) => { el.value = value; },
    },
    Node: { TEXT_NODE: 3 },
    Event: class { constructor(type) { this.type = type; } },
    MentionAC: {
      icons: { folder: "folder", message: "message" },
      svgHtml: () => "<svg></svg>",
      open: (mode, input) => mentionOpens.push([mode, input]),
      hide() {},
    },
    Sessions: { sendMessage() {} },
    Skills: { createInSession() {}, toggleImportBar() {} },
    fetch: async () => ({ json: async () => ({ skills }) }),
  });

  vm.runInContext(fs.readFileSync(sourcePath("skills.js"), "utf8"), context);
  const SkillAC = context.Clacky.SkillAC;
  SkillAC.init();
  return { SkillAC, nodes, context, mentionOpens };
}

// ── The parser contract, mirroring parse_skill_command ────────────────────────
// Kept in this exact shape because slash_command_spec.rb feeds the same table to
// the Ruby parser and asserts both sides agree.
const COMMANDS = [
  "/commit",
  "/media-gen",
  "/skill-add https://example.com/x.zip",
  "/guizang-ppt-skill:create",
  "/foo.bar",
  "/deploy --force",
  "/commit\nsecond line",
];

const PLAIN_MESSAGES = [
  "/Users/alice/Download",
  "/Users/jiujiu/Download",
  "/tmp/bar",
  "/xxxx/zzzz/",
  "/",
  "//",
  "/ leading space",
  "/\ttab",
  "hello",
  "",
  "please run /commit for me",
  " /commit",
];

function parserTests() {
  const { SkillAC } = loadSkillAC([]);
  const name = SkillAC.slashCommandName;

  for (const input of COMMANDS) {
    assert.ok(name(input), `${JSON.stringify(input)} is a slash command`);
  }
  for (const input of PLAIN_MESSAGES) {
    assert.equal(name(input), null, `${JSON.stringify(input)} is a plain message, not a command`);
  }

  assert.equal(name("/commit"), "commit");
  assert.equal(name("/skill-add https://example.com/x.zip"), "skill-add",
    "a slash inside the arguments does not make the input a path");
  assert.equal(name("/guizang-ppt-skill:create"), "guizang-ppt-skill:create",
    "non-slug command names stay intact — the lookup decides, not the parser");
  assert.equal(name("／commit"), "commit", "full-width slash from an IME counts");
  assert.equal(name("、commit"), "commit", "Chinese dunhao from an IME counts");
  assert.equal(name(null), null);
  assert.equal(name(undefined), null);
}

// ── The palette must not open over a pasted path ──────────────────────────────
async function paletteTests() {
  const skills = [{ name: "media-gen", description: "media", source_type: "global_clacky" }];
  const { SkillAC, nodes } = loadSkillAC(skills);
  SkillAC.loadForSession("s1");
  const input = nodes["user-input"];
  const fire = async value => {
    input.value = value;
    await nodes["user-input"].handlers.input();
    await new Promise(resolve => setTimeout(resolve, 0));
  };

  await fire("/media");
  assert.equal(SkillAC.visible, true, "a real command opens the palette");

  await fire("/Users/jiujiu/Download");
  assert.equal(SkillAC.visible, false, "a pasted path leaves the palette closed");

  await fire("/");
  assert.equal(SkillAC.visible, true, "a bare slash still opens the full palette");

  await fire("/Users/");
  assert.equal(SkillAC.visible, false, "the palette closes as soon as the path shape appears");
}

// ── Enter must never be swallowed when there is nothing to pick ───────────────
async function enterFallthroughTests() {
  const open = async (skills, value) => {
    const loaded = loadSkillAC(skills);
    vm.runInContext("Sessions.sendMessage = () => { globalThis.sentCount = (globalThis.sentCount || 0) + 1; };", loaded.context);
    loaded.SkillAC.loadForSession("s1");
    loaded.nodes["user-input"].value = value;
    await loaded.nodes["user-input"].handlers.input();
    await new Promise(resolve => setTimeout(resolve, 0));
    loaded.sent = () => vm.runInContext("globalThis.sentCount || 0", loaded.context);
    loaded.press = key => {
      let defaultPrevented = false;
      loaded.nodes["user-input"].handlers.keydown({
        key, shiftKey: false, preventDefault: () => { defaultPrevented = true; },
      });
      return defaultPrevented;
    };
    return loaded;
  };

  const empty = await open([], "/");
  assert.equal(empty.SkillAC.visible, true, "the empty state keeps the palette visible");
  assert.equal(empty.press("Enter"), true, "Enter is still consumed by the composer to send");
  assert.equal(empty.sent(), 1, "Enter sends the message instead of being swallowed");
  assert.equal(empty.SkillAC.visible, false, "Enter closes the empty palette on its way out");

  const emptyTab = await open([], "/");
  assert.equal(emptyTab.press("Tab"), false, "Tab is not swallowed when there is nothing to complete");
  assert.equal(emptyTab.sent(), 0, "Tab does not send");

  const path = await open([{ name: "media-gen", description: "m", source_type: "global_clacky" }],
    "/Users/jiujiu/Download");
  assert.equal(path.SkillAC.visible, false, "a pasted path never opens the palette");
  assert.equal(path.press("Enter"), true);
  assert.equal(path.sent(), 1, "a path-only message can be sent with Enter");

  const match = await open([{ name: "media-gen", description: "m", source_type: "global_clacky" }], "/media");
  assert.equal(match.SkillAC.visible, true);
  assert.equal(match.press("Enter"), true, "Enter on a real match is consumed by the palette");
  assert.equal(match.sent(), 0, "Enter completes the command instead of sending");
  assert.equal(match.nodes["user-input"].value, "/media-gen ");
}

// ── A path in a sent message is never painted as a command ───────────────────
function highlightTests() {
  const { SkillAC, context } = loadSkillAC([]);
  vm.runInContext("SkillAC.loadForSession('s1');", context);

  const render = SkillAC.renderUserMessageHtml;
  assert.equal(render("/Users/media-gen/notes", null, null), "/Users/media-gen/notes",
    "a path is escaped as plain text even when its first segment names a skill");
  assert.match(render("/media-gen make art", "media-gen", "media-gen"),
    /^<span class="msg-slash-cmd">\/media-gen<\/span> make art$/,
    "a real command keeps its highlight and its arguments");
  assert.equal(render("/unknown-skill hi", null, null), "/unknown-skill hi");
}

// ── The + button: "Add" actions on top, skills below, existing text kept ──────
async function plusMenuTests() {
  const skills = [{ name: "media-gen", name_zh: "媒体生成", description: "m", source_type: "global_clacky" }];
  const loaded = loadSkillAC(skills);
  const { SkillAC, nodes, context, mentionOpens } = loaded;
  // DOM-backed composer stub: text lives in child text nodes, chips are elements.
  vm.runInContext(`
    Composer.text = el => el.children.filter(c => c.nodeType === 3).map(c => c.nodeValue).join("");
    Composer.setText = (el, v) => { el.children = []; el.appendChild(document.createTextNode(v)); };
    Composer.focusEnd = () => {};
  `, context);
  SkillAC.loadForSession("s1");
  const input = nodes["user-input"];
  const settle = () => new Promise(resolve => setTimeout(resolve, 0));
  const press = key => input.handlers.keydown({ key, shiftKey: false, preventDefault() {} });

  nodes["btn-slash"].handlers.click();
  await settle();
  assert.equal(SkillAC.visible, true, "the + button opens the menu");
  assert.equal(nodes.actions.style.display, "", "the Add group is shown");
  assert.equal(nodes.actions.querySelectorAll(".skill-ac-item").length, 3);
  assert.equal(Composer_text(context, input), "", "opening the + menu does not type a slash");
  assert.equal(SkillAC.activeIndex, -1, "the + menu opens with nothing highlighted");

  press("ArrowDown");
  press("Enter");
  assert.equal(nodes["image-file-input"].clicked, 1, "the first action opens the file picker");
  assert.equal(SkillAC.visible, false);

  nodes["btn-slash"].handlers.click();
  await settle();
  press("ArrowDown"); press("ArrowDown");
  press("Enter");
  assert.deepEqual(mentionOpens.slice(-1)[0], ["files", "user-input"],
    "reference actions open the mention menu on this composer");

  // Picking a skill keeps what the user already wrote, chips included.
  const chip = new Element("span");
  input.children = [];
  input.appendChild(context.document.createTextNode("draft text"));
  input.appendChild(chip);
  nodes["btn-slash"].handlers.click();
  await settle();
  press("ArrowDown"); press("ArrowDown"); press("ArrowDown"); press("ArrowDown");
  press("Enter");
  assert.equal(Composer_text(context, input), "/media-gen draft text");
  assert.ok(input.children.includes(chip), "existing chips survive picking a skill");

  // A second pick replaces the leading command instead of stacking it.
  nodes["btn-slash"].handlers.click();
  await settle();
  press("ArrowUp");
  press("Enter");
  assert.equal(Composer_text(context, input), "/media-gen draft text");

  // Typing / still opens the skills-only palette.
  input.children = [];
  input.appendChild(context.document.createTextNode("/"));
  await input.handlers.input();
  await settle();
  assert.equal(SkillAC.visible, true);
  assert.equal(nodes.actions.style.display, "none", "typed / hides the Add group");
}

function Composer_text(context, el) {
  return vm.runInContext("Composer.text", context)(el);
}

(async () => {
  parserTests();
  await plusMenuTests();
  await paletteTests();
  await enterFallthroughTests();
  highlightTests();
  console.log("ok - slash command detection");
})().catch(error => {
  console.error(error);
  process.exit(1);
});
