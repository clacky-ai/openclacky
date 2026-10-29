"use strict";

// Attachment chips (composer cards and message bubbles) must draw the same
// file-type icon as the workspace file tree, via Clacky.WorkspaceView.fileIcon.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = name => fs.readFileSync(path.resolve(__dirname, "../../lib/clacky/web", name), "utf8");
function extract(text, signature, indent = "  ") {
  const start = text.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  return text.slice(start, text.indexOf(`\n${indent}}\n`, start) + indent.length + 3);
}

const iconCalls = [];
const fileIcon = name => { iconCalls.push(name); return `<svg data-icon="${name}"></svg>`; };
const escapeHtml = v => String(v).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;");

const sessions = source("sessions.js");
const chat = vm.createContext({ Clacky: { WorkspaceView: { fileIcon } }, escapeHtml });
vm.runInContext(extract(sessions, "function _attachmentBadge("), chat);
if (sessions.includes("function _fileIcon(")) vm.runInContext(extract(sessions, "function _fileIcon("), chat);

const badge = chat._attachmentBadge("report.docx", "application/msword", "/tmp/report.docx");
assert.match(badge, /<span class="msg-pdf-badge-icon"><svg data-icon="report.docx"><\/svg><\/span>/);

const composer = extract(sessions, "function _renderAttachmentPreviews(");
assert.match(composer, /icon\.innerHTML = _fileIcon\(f\.name\)/, "composer card must use the workspace icon");

const newSession = source("features/new-session/view.js");
const ns = vm.createContext({
  Clacky: { WorkspaceView: { fileIcon } },
  escapeHtml,
  MentionAC: {},
  _pendingImages: [],
  _pendingFiles: [{ name: "data.csv", path: "/tmp/data.csv", mime_type: "text/csv" }],
});
vm.runInContext(extract(newSession, "function _buildBubbleHtml("), ns);
assert.match(ns._buildBubbleHtml(""), /<span class="msg-pdf-badge-icon"><svg data-icon="data.csv"><\/svg><\/span>/);
assert.match(newSession, /icon\.innerHTML = Clacky\.WorkspaceView\.fileIcon\(f\.name\)/, "new-session card must use the workspace icon");
assert.doesNotMatch(newSession + sessions, /_docTypeIcon/);

console.log("Attachment file icon checks passed");
