## How to open

- **Knowledge Base in the sidebar** (below Creator Center): opens the manager where you organise and import documents.
- **Pick the Knowledge Base agent in a session**: questions are answered from your documents only.
- Status: off by default. Enable **Knowledge Base** under **Extensions › All › Official** first; the sidebar entry and the agent card only appear after that. Turning it off removes the entry, the tools and the automatic retrieval together, while the documents you already imported are left untouched.

## How to use

### Managing documents

Open **Knowledge Base** in the sidebar — a full-page manager:

- **Folders**: the left column lists top-level folders (one per book or project); click + to create one, hover to rename or delete. The right side shows the selected folder as a card list, with folders of any depth (book → chapter → section) and a breadcrumb to jump back up.
- **Search and sort**: the search box searches titles and sources in the current location and everything below it; the menu beside it sorts by name (default) or last update.
- **Editing**: click a document to open the Markdown editor — edit on the left, live preview on the right; changes take effect as soon as you save. Documents not placed in any folder appear under "Unfiled".
- **Organising**: hover a document to rename it, move it (to any level of any folder) or delete it; sub-folders can be renamed and deleted (deleting moves the folder and everything in it to the trash). Folders are for managing only — retrieval always covers the whole knowledge base, and citations include the folder (e.g. "Tea Book / Chapter 1").

### Adding documents

- **Upload file**: saved into the location that is open (pick a folder first). One md, txt, PDF or Word (doc / docx / wps) file at a time. It is converted to text and opened in the editor for preview; fix anything you need, then click **Import** to save it. Cancel discards it.
- **Import folder**: pick a folder in the system folder dialog (a folder on your own computer, also when the server runs in the cloud). After the browser asks you to confirm uploading N files, a list of the supported files found is shown by relative path; untick any you don't want, then Import uploads and saves them one by one, without per-file content preview. The picked folder is placed inside the current folder with its whole sub-folder structure kept, so importing several books gives one folder per book. The import is a one-off copy.
- PDF and Word text is recognised automatically — scans and complex layouts may contain mistakes; you can open any document later to fix it.
- **Delete**: documents and folders are moved to the trash and can be restored. A folder stays when its last document is deleted.

### Recall test

Type a question the way a user would and see which passages the Knowledge Base agent retrieves. The top few results are marked "Used". Use it to check coverage and whether real wording finds the right document. The box remembers your last searches — click the clock icon to re-run one, or clear them all.

### Asking questions

Switch the session agent to **Knowledge Base** and ask. How it works:

- **Automatic retrieval before every question**: the most relevant passages are handed to the AI together with their titles and sources, before it answers.
- **Extra lookups when needed**: search again with different keywords, or read a whole document and look for a keyword inside it.
- **Answering rules**: check the knowledge base first, name the source in plain words when it matters, and say so plainly when the material doesn't cover something instead of making it up.

### Titles and sources

Uploaded md files may start with a small block that sets the title and source shown with the passage; without it the file name is used and the source stays empty:

```markdown
---
title: Main Gate
source: Building Annals, p. 12
---

Body text…
```

### Where it applies

Once it's on, choose **Knowledge Base** under **Settings › General › Default Agent** and it will be used for:

- New sessions
- Quick "New session" in the sidebar
- Channel sessions (Feishu, WeChat, etc.)

Switch the default back to **General** and the knowledge base only applies to sessions where you pick the **Knowledge Base** card yourself.

### How retrieval works

Retrieval runs on the local machine — no network access and no embedding model to configure.

## Notes

- The Knowledge Base agent can only search your documents: it can't run commands, read or write files, search the web, drive the browser, use skills, or read or update long-term memory. Anything else gets one fixed sentence back — "This question is outside the knowledge base, so I can't answer it." — with no alternatives, commands or suggestions (a greeting or "who are you" may get one short self-introduction first). When you need the full toolset, switch to the **General** agent.
- Other agents (General, Coding, etc.) get no knowledge injection and don't have the two tools above. Sub-agents are not injected either.
- Scheduled tasks always run on the General agent and are unaffected by the default agent setting.
