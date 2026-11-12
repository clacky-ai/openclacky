"use strict";

// Messages saved while the agent still emitted hosted-platform file refs
// (`/workspace/projects/<base64url>` → `cch1:file:///abs/path`) must render as
// clickable file:// links instead of dead localhost URLs.

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

const ctx = vm.createContext({ atob, Uint8Array, TextDecoder, encodeURI, decodeURI });
vm.runInContext(extract(source, "function _decodeProjectRef("), ctx);
vm.runInContext(extract(source, "function _restoreProjectFileRefs("), ctx);
vm.runInContext(extract(source, "function _normalizeFileHref("), ctx);

const token = Buffer.from("cch1:file:///tmp/报告.pdf", "utf8")
  .toString("base64")
  .replace(/\+/g, "-")
  .replace(/\//g, "_")
  .replace(/=+$/, "");

assert.equal(ctx._decodeProjectRef(`/workspace/projects/${token}`), "file:///tmp/报告.pdf");
assert.equal(ctx._decodeProjectRef(`http://127.0.0.1:7070/workspace/projects/${token}`), "file:///tmp/报告.pdf");
assert.equal(ctx._decodeProjectRef("/workspace/projects/!!!bad"), null);

assert.equal(
  ctx._restoreProjectFileRefs(`[报告](</workspace/projects/${token}>)`),
  `[报告](</workspace/projects/${token}>)`,
  "angle-bracket links are left to marked"
);
assert.equal(
  ctx._restoreProjectFileRefs(`[报告](/workspace/projects/${token})`),
  "[报告](file:///tmp/报告.pdf)"
);
assert.equal(
  ctx._restoreProjectFileRefs(`![图](/workspace/projects/${token})`),
  "![图](file:///tmp/报告.pdf)"
);
assert.equal(ctx._restoreProjectFileRefs("[api](/api/sessions)"), "[api](/api/sessions)");
assert.equal(
  ctx._normalizeFileHref(`/workspace/projects/${token}`),
  "file:///tmp/%E6%8A%A5%E5%91%8A.pdf"
);
