"use strict";

// The streaming preview repairs a copy with remend, then patches the bubble one
// top-level block at a time. These checks replay replies one character at a
// time and fail if a word that was already on screen disappears, and check
// that settled blocks keep their DOM nodes.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const web = path.resolve(__dirname, "../../lib/clacky/web");
const sessions = fs.readFileSync(path.join(web, "sessions.js"), "utf8");

function extractFunction(src, name) {
  const start = src.indexOf("function " + name + "(");
  assert.ok(start >= 0, "missing " + name);
  let i = src.indexOf("{", start);
  let depth = 0;
  let quote = null;
  for (; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      if (c === "\\") { i++; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "/" && src[i + 1] === "/") {
      const nl = src.indexOf("\n", i);
      i = nl === -1 ? src.length : nl;
      continue;
    }
    if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      i = end === -1 ? src.length : end + 1;
      continue;
    }
    // Regex literals. A character class can hold braces and backticks, which
    // would otherwise move the brace depth or open a fake template string.
    if (c === "/" && /[(,=:!&|?]\s*$/.test(src.slice(Math.max(0, i - 8), i))) {
      i++;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === "[") {
          i++;
          while (i < src.length && src[i] !== "]") {
            if (src[i] === "\\") i++;
            i++;
          }
          i++;
          continue;
        }
        if (src[i] === "/") break;
        i++;
      }
      continue;
    }
    if (c === "'" || c === '"' || c === "`") { quote = c; continue; }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unterminated " + name);
}

// Just enough DOM for _patchStreamingBlocks: each parsed block becomes one node.
class FakeNode {
  constructor(html) { this.html = html; this.parent = null; }
  remove() {
    if (!this.parent) return;
    this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
}

class FakeHost {
  constructor() { this.children = []; }
  appendChild(fragment) {
    for (const node of fragment.childNodes.splice(0)) {
      node.parent = this;
      this.children.push(node);
    }
  }
}

const document = {
  createElement() {
    const tpl = { content: { childNodes: [] } };
    Object.defineProperty(tpl, "innerHTML", {
      set(html) { tpl.content.childNodes = [new FakeNode(html)]; },
    });
    return tpl;
  },
};

const context = vm.createContext({ document, globalThis: null });
context.globalThis = context;
vm.runInContext(fs.readFileSync(path.join(web, "vendor/marked/marked.min.js"), "utf8"), context);
vm.runInContext(fs.readFileSync(path.join(web, "vendor/remend/remend.min.js"), "utf8"), context);
assert.equal(typeof context.remend, "function", "remend bundle must expose a global");

// The code header shows the language label, so the preview does too.
vm.runInContext(`
  const _previewRenderer = new marked.Renderer();
  _previewRenderer.code = ({ text, lang }) => "<pre>" + (lang || "") + " " + text + "</pre>";
  function _markedParse(text) {
    return marked.parse(text, { breaks: true, gfm: true, renderer: _previewRenderer });
  }
`, context);
for (const name of ["_balanceHighlightLines", "_streamingCodeDom", "_growStreamingCodeBlock", "_repairStreamingMarkdown", "_patchStreamingBlocks", "_splitInlineThink"]) {
  vm.runInContext(extractFunction(sessions, name), context);
}
const balance = vm.runInContext("_balanceHighlightLines", context);
const repair = vm.runInContext("_repairStreamingMarkdown", context);
const patch = vm.runInContext("_patchStreamingBlocks", context);
const splitThink = vm.runInContext("_splitInlineThink", context);

function visible(html) {
  return html
    .replace(/<br>/g, " ")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, " ")
    .trim();
}

// Marker characters (and remend's zero-width guard) may come and go. Everything
// else is the words the reader is following, and those must only grow.
function words(html) {
  return visible(html)
    .replace(/[*_~`[\]()\-=\u200b]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function stream(sample, onFrame) {
  const host = new FakeHost();
  const state = { raws: [], nodes: [] };
  for (let n = 1; n <= sample.length; n++) {
    patch(host, sample.slice(0, n), state);
    onFrame(sample.slice(0, n), host);
  }
  return host;
}

const samples = [
  "请看 **重点** 和 `npm install` 以及 [文档](https://example.com/guide) 就好。",
  "Use ~~删掉~~ this and keep going.",
  "A paragraph that keeps growing with no markdown at all.",
  "```js\nconst x = 1;\nconsole.log(x);\n```\nDone.",
  "before\n```js\nconst **x = 1;\n```\n**after",
  "运行 ``cmd --flag`` 然后结束。",
  "要点如下：\n- 第一项 **粗体**\n- 第二项 *斜体*\n\n结尾段落。",
  "标题行\n===\n正文",
  "[".repeat(20) + "嵌套](https://example.com/x) 完",
];

for (const sample of samples) {
  let prev = "";
  stream(sample, (slice, host) => {
    const got = words(host.children.map(n => n.html).join(" "));
    assert.ok(
      got.startsWith(prev),
      "tail shrank at " + JSON.stringify(slice) +
        "\n  had " + JSON.stringify(prev) +
        "\n  now " + JSON.stringify(got) +
        "\n  repair " + JSON.stringify(repair(slice))
    );
    prev = got;
  });
}

// A line followed by a list must not flash as a setext heading while "-" arrives.
for (const slice of ["要点如下：\n-", "要点如下：\n- ", "要点如下：\n--"]) {
  assert.doesNotMatch(context.marked.parse(repair(slice)), /<h[12]>/, JSON.stringify(slice));
}

assert.equal(repair("请看 **重点"), "请看 **重点**");
assert.equal(repair("以及 [文档](https://example.com/gui"), "以及 文档");
assert.equal(repair("以及 [文档"), "以及 文档");
assert.equal(repair("看 ![封面](https://ex"), "看 ");
assert.equal(repair("看 ![封"), "看 ");
assert.equal(repair("~~删掉~"), "~~删掉~~");
assert.equal(repair("snake_case and $12 stay"), "snake_case and $12 stay");
assert.equal(repair(""), "");

// Settled blocks keep their nodes; only the growing tail is replaced.
{
  const host = new FakeHost();
  const state = { raws: [], nodes: [] };
  patch(host, "第一段。\n\n第二段", state);
  const first = host.children[0];
  patch(host, "第一段。\n\n第二段继续", state);
  assert.equal(host.children[0], first, "a settled paragraph must keep its DOM node");
  assert.match(host.children[1].html, /第二段继续/);
  assert.equal(host.children.length, 2);
}

// An open fence is colored on the same path as a finished one. Once a paragraph
// follows the fence, growing that paragraph must not repaint the code block.
{
  const host = new FakeHost();
  const state = { raws: [], nodes: [] };
  patch(host, "```js\nconst x = 1;\n```\n\n下一段", state);
  const code = host.children[0];
  assert.match(code.html, /<pre>js /);
  patch(host, "```js\nconst x = 1;\n```\n\n下一段继续", state);
  assert.equal(host.children[0], code, "a settled code block must keep its DOM node");
}
// An unfinished JSX tag opens a span on one line and closes it on the next.
// Each streaming line is its own element, so the open span is closed at the
// end of the line and reopened on the following line.
{
  const html = '<span class="language-xml"><span class="hljs-tag">&lt;<span class="hljs-name">Row</span>\n' +
    '          <span class="hljs-attr">key</span>=<span class="hljs-string">{item.id}</span>';
  const lines = balance(html);
  for (const line of lines) {
    const open = (line.match(/<span\b/g) || []).length;
    const close = (line.match(/<\/span>/g) || []).length;
    assert.equal(open, close, line);
  }
  assert.match(lines[1], /^<span class="language-xml"><span class="hljs-tag">/);
}

// A replay snapshot that rewrites the text rebuilds from the first changed block.
{
  const host = new FakeHost();
  const state = { raws: [], nodes: [] };
  patch(host, "甲\n\n乙\n\n丙", state);
  patch(host, "甲\n\n丁", state);
  assert.deepEqual([...host.children.map(n => visible(n.html))], ["甲", "丁"]);
}

assert.deepEqual({ ...splitThink("plain") }, { reasoning: "", text: "plain" });
assert.deepEqual({ ...splitThink("<think>想一想") }, { reasoning: "想一想", text: "" });
assert.deepEqual({ ...splitThink("<think>想\n</think>\n\n答案") }, { reasoning: "想\n", text: "答案" });

console.log("streaming markdown preview: ok");
