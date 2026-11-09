// Streaming markdown preview helpers. Exposes two globals:
//   remend       — closes unfinished markdown in the live preview.
//   jsxHighlight — TanStack Highlight, TSX and JSX only. Same idea as
//                  Streamdown's per-token coloring, without Shiki.
// Build:
//   npx esbuild entry.js --bundle --minify --format=iife --legal-comments=inline \
//     --banner:js='/*! remend 1.4.0 | Apache-2.0 | https://github.com/vercel/streamdown/tree/main/packages/remend */' \
//     --outfile=streaming-markdown.min.js
import remend from "remend";
import { createHighlighter } from "@tanstack/highlight/core";
import { jsx } from "@tanstack/highlight/languages/jsx";
import { tsx } from "@tanstack/highlight/languages/tsx";

globalThis.remend = remend;

const highlighter = createHighlighter({ languages: [jsx, tsx] });

const LANGS = {
  jsx: "jsx",
  javascriptreact: "jsx",
  tsx: "tsx",
  typescriptreact: "tsx",
};

// Emit highlight.js class names so TSX/JSX share hljs-theme.css with every
// other language instead of carrying a second palette.
const HLJS_CLASS = {
  function: "hljs-title function_",
  tag: "hljs-name",
};

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// A token value may contain newlines. Split them so a span never crosses a
// line that we later put in its own element.
function tokensToHtml(tokens) {
  let html = "";
  for (const token of tokens) {
    const parts = token.value.split("\n");
    for (let i = 0; i < parts.length; i++) {
      if (i) html += "\n";
      if (!parts[i]) continue;
      const text = escapeHtml(parts[i]);
      html += token.className
        ? `<span class="${HLJS_CLASS[token.className] || "hljs-" + token.className}">${text}</span>`
        : text;
    }
  }
  return html;
}

globalThis.jsxHighlight = (code, lang) => {
  const mapped = LANGS[String(lang || "").toLowerCase()];
  if (!mapped) return null;
  try {
    return tokensToHtml(highlighter.tokenize(code, { lang: mapped }).tokens);
  } catch (_) {
    return null;
  }
};
