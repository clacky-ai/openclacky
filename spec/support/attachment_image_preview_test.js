"use strict";

// Composer/bubble thumbnails load from /api/local-image, so only formats that
// endpoint serves may render as <img>; everything else falls back to a card.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sessions = fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web/sessions.js"), "utf8");
const start = sessions.indexOf("  const IMAGE_FILE_EXTENSIONS");
const end = sessions.indexOf("  function _attachmentImageUrl(");
assert.ok(start >= 0 && end > start, "missing _isImageAttachment block");

const ctx = vm.createContext({});
vm.runInContext(sessions.slice(start, end) + "\nthis._isImageAttachment = _isImageAttachment;", ctx);

for (const name of ["a.png", "b.JPG", "c.jpeg", "d.gif", "e.webp", "logo.svg"]) {
  assert.equal(ctx._isImageAttachment({ name }), true, name);
}
for (const [name, mime] of [["scan.bmp", "image/bmp"], ["p.heic", "image/heic"], ["t.tiff", "image/tiff"], ["r.pdf", "application/pdf"]]) {
  assert.equal(ctx._isImageAttachment({ name, mime_type: mime }), false, name);
}

console.log("Attachment image preview checks passed");
