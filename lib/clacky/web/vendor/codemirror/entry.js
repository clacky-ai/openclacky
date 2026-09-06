// CodeMirror 6 bundle entry — exposes a single `CM` global with the editor
// core plus mainstream language support for the workspace file viewer.
import { EditorState } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLineGutter,
  highlightSpecialChars,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
  highlightActiveLine,
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
import { search, searchKeymap, highlightSelectionMatches } from "@codemirror/search";
import {
  bracketMatching,
  foldGutter,
  foldKeymap,
  indentOnInput,
  syntaxHighlighting,
  defaultHighlightStyle,
  StreamLanguage,
} from "@codemirror/language";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { oneDark } from "@codemirror/theme-one-dark";

// ── Lezer languages (best highlighting quality) ────────────────────────────
import { python } from "@codemirror/lang-python";
import {
  javascript,
  typescriptLanguage,
  jsxLanguage,
  tsxLanguage,
} from "@codemirror/lang-javascript";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { json } from "@codemirror/lang-json";
import { sql } from "@codemirror/lang-sql";
import { xml } from "@codemirror/lang-xml";
import { rust } from "@codemirror/lang-rust";
import { java } from "@codemirror/lang-java";
import { cpp } from "@codemirror/lang-cpp";
import { php } from "@codemirror/lang-php";

// ── Legacy (StreamParser) languages ────────────────────────────────────────
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { go } from "@codemirror/legacy-modes/mode/go";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { yaml } from "@codemirror/legacy-modes/mode/yaml";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";

const rubyLang = StreamLanguage.define(ruby);
const goLang = StreamLanguage.define(go);
const shellLang = StreamLanguage.define(shell);
const yamlLang = StreamLanguage.define(yaml);
const tomlLang = StreamLanguage.define(toml);
const dockerfileLang = StreamLanguage.define(dockerFile);

// Lezer languages are already functions returning a LanguageSupport.
// LRLanguage objects and StreamLanguage supports are wrapped so CodeEditor
// can call every language uniformly as `CM.<lang>()`.
const typescript = () => typescriptLanguage;
const jsx = () => jsxLanguage;
const tsx = () => tsxLanguage;
const rubyFn = () => rubyLang;
const goFn = () => goLang;
const shellFn = () => shellLang;
const yamlFn = () => yamlLang;
const tomlFn = () => tomlLang;
const dockerfileFn = () => dockerfileLang;

export {
  EditorState,
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLineGutter,
  highlightSpecialChars,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
  highlightActiveLine,
  highlightSelectionMatches,
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  search,
  searchKeymap,
  bracketMatching,
  foldGutter,
  foldKeymap,
  indentOnInput,
  syntaxHighlighting,
  defaultHighlightStyle,
  StreamLanguage,
  markdown,
  markdownLanguage,
  oneDark,
  python,
  javascript,
  typescript,
  jsx,
  tsx,
  html,
  css,
  json,
  sql,
  xml,
  rust,
  java,
  cpp,
  php,
  rubyFn as ruby,
  goFn as go,
  shellFn as shell,
  yamlFn as yaml,
  tomlFn as toml,
  dockerfileFn as dockerfile,
};
