# Knowledge Base (knowledge)

This extension adds a **Knowledge Base** agent. It builds on the **General** agent and adds three things:

- **Automatic retrieval before every question**: the most relevant passages are injected for the AI, with their titles and sources, before it answers.
- **Follow-up lookups on demand**: the AI can call two tools:
  - `kb_search`: search again with different keywords
  - `kb_read`: read a whole document by id; pass `pattern` to grep within that document only
- **Answering rules**: check the knowledge base first, name the source in plain words when it matters, and say so plainly when the material doesn't cover something instead of making it up.

Other agents (General, Coding, etc.) get no knowledge injection and don't have the two tools above. Sub-agents are not injected either.

## Turning it on

This extension is **off by default**. Go to **Extensions › All › Official** and click the `+` next to **Knowledge Base**; the **Knowledge Base** card then appears on the new-session page. Turning it off removes the card, the tools and the automatic retrieval together; your files in `~/.clacky/knowledge/` are left untouched.

## Where it applies

Once it's on, choose **Knowledge Base** under **Settings › General › Default Agent** and it will be used for:

- New sessions
- Quick "New session" in the sidebar
- Channel sessions (Feishu, WeChat, etc.)
- Scheduled tasks

Switch the default back to **General** and the knowledge base only applies to sessions where you pick the **Knowledge Base** card yourself.

## Getting started

**Drop md files into `~/.clacky/knowledge/entries/` and they take effect** — no configuration needed. The directory is created automatically when the server starts; organise sub-folders however you like (e.g. book → chapter → section); the panel shows them as a folder tree.

```
~/.clacky/knowledge/
└── entries/
    ├── places/
    │   └── main-gate.md
    └── people/
        └── founder.md
```

Set the `CLACKY_KNOWLEDGE_DIR` environment variable to use a different directory.

## kb.yml (optional)

Only create `~/.clacky/knowledge/kb.yml` if you want to turn the knowledge base off or tune its parameters:

```yaml
enabled: false        # false turns it off; omit it (or the file) to keep it on
inject_top_k: 5       # passages injected per question, default 5
version: 1            # content pack version, used for export / import
```

The management page does not expose these settings yet; edit this file by hand when needed.

## Entry format

Each entry is an md file with optional frontmatter (every field can be omitted):

```markdown
---
id: main-gate            # defaults to the path relative to entries/
title: Main Gate         # defaults to the file name
source: Building Annals, p. 12
---

Body text…
```

## Adding content

Once enabled, a **Knowledge Base** entry appears in the sidebar below **Creator Center**. It opens a full-page manager:

- **Folders**: the left column lists top-level folders (one per book or project); click + to create one, hover to rename or delete. The right side shows the selected folder as a card list where you can create folders of any depth (e.g. book → chapter → section), with a breadcrumb to jump back up. The search box searches titles and sources in the current location and everything below it. Sort the list by name (default) or by last update from the menu beside it. Click a document to open the Markdown editor — edit on the left, live preview on the right; changes take effect as soon as you save. Every document lives in some folder; files placed directly in `entries/` appear under "Unfiled" on the left.
- **Organise**: hover a document to rename it, move it (to any level of any folder) or delete it; sub-folders can be renamed and deleted (deleting moves the folder and everything in it to the trash). Folders are for managing only — retrieval always covers the whole knowledge base, and citations include the folder (e.g. "Tea Book / Chapter 1").
- **Add data source**:
  - **Upload file**: saved into the location that is open (pick a folder first). One md, txt, PDF or Word (doc / docx / wps) file at a time. It is converted to text and opened in the editor for preview; fix anything you need, then click **Import** to save it. Cancel discards it.
  - **Import folder**: pick a folder in the system folder dialog (a folder on your own computer, also when the server runs in the cloud). After the browser asks you to confirm uploading N files, a list of the supported files found (sub-folders included, hidden files skipped, up to 500) is shown by relative path; untick any you don't want, then Import uploads and saves them one by one, without per-file content preview. The picked folder is placed inside the current folder with its whole sub-folder structure kept, so importing several books gives one folder per book. The import is a one-off copy; later changes to the folder are not picked up.
  - PDF and Word text is recognised automatically — scans and complex layouts may contain mistakes; you can open any document later to fix it.
- **Delete**: documents and folders are moved to the trash and can be restored. A folder stays when its last document is deleted.
- **Recall test**: type a question the way a user would and see which passages the Knowledge Base agent retrieves. The top `top_k` results are marked "Used". Use it to check coverage and whether real wording finds the right document. The box remembers your last searches — click the clock icon to re-run one, or clear them all.

You can still drop md files into `entries/` directly; both ways are equivalent. Changes take effect on the next question (the index is rebuilt based on file modification times).

## How retrieval works

In-memory BM25: Chinese is tokenised into adjacent character pairs, English and numbers into words; bodies are split by paragraph into passages of about 600 characters, and the best-matching passage of each entry is used. No embedding model and no network access required.
