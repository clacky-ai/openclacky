"use strict";

// Links whose target is a local path with spaces or parentheses must survive
// marked's link tokenizer. _encodeFileUrlsInMarkdown percent-encodes the path
// before marked parses it, and a destination ends at the first unbalanced ")"
// so paired parentheses in a file name stay part of the path.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/sessions.js"), "utf8");

function extract(text, signature) {
  const start = text.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  return text.slice(start, text.indexOf("\n  }\n", start) + 5);
}

const ctx = vm.createContext({ encodeURI, decodeURI });
vm.runInContext(extract(source, "function _encodeFileUrlsInMarkdown("), ctx);

const encode = ctx._encodeFileUrlsInMarkdown;

assert.equal(
  encode("[报告](file:///tmp/a/with space.pdf)"),
  "[报告](file:///tmp/a/with%20space.pdf)"
);
assert.equal(
  encode("[报告](file:///tmp/a/备份(旧).pdf)"),
  "[报告](file:///tmp/a/%E5%A4%87%E4%BB%BD(%E6%97%A7).pdf)"
);
assert.equal(
  encode("[报告](file:///tmp/a/备份(旧) 副本.pdf)"),
  "[报告](file:///tmp/a/%E5%A4%87%E4%BB%BD(%E6%97%A7)%20%E5%89%AF%E6%9C%AC.pdf)"
);
assert.equal(
  encode("![图](file:///tmp/a/a(1) b(2).png)"),
  "![图](file:///tmp/a/a(1)%20b(2).png)"
);
assert.equal(encode("[报告](file:///tmp/a/plain.pdf)"), "[报告](file:///tmp/a/plain.pdf)");

const unbalanced = "[x](file:///tmp/a/foo(bar.pdf)";
assert.equal(encode(unbalanced), unbalanced, "unbalanced parenthesis is left untouched");

assert.equal(
  encode("[一](file:///tmp/a/x(1).pdf) [二](file:///tmp/a/y(2).pdf)"),
  "[一](file:///tmp/a/x(1).pdf) [二](file:///tmp/a/y(2).pdf)"
);

assert.equal(encode("[api](/api/sessions)"), "[api](/api/sessions)");
