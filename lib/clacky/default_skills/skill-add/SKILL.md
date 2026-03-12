---
name: skill-add
description: 'Install skills from a zip URL, or create new skills interactively. Use this skill whenever the user wants to install a skill from a zip URL, add a new skill to Clacky, create a custom skill from scratch, or use commands like /skill-add. Trigger on phrases like: install skill, add skill, skill install, create a skill, 安装skill, 添加skill, 创建skill, install from zip, skill from url, skill from zip, add skill from zip.'
disable-model-invocation: false
user-invocable: true
---

# Skill Add — Installation & Creation

A skill management tool that installs skills from a zip URL or creates new skills interactively.

## Quick Reference

- **Zip URL** → run `install_from_zip.rb` script (see below for the exact path)
- **Text description or no arguments** → create skill interactively via conversation

## Finding the Script Path

The `install_from_zip.rb` script lives inside this skill's own directory. Skills are stored in one of two locations:
- Project-level: `.clacky/skills/skill-add/` (relative to current working directory)
- Global: `~/.clacky/skills/skill-add/`

Use `safe_shell` to locate the script at runtime:
```bash
ruby "$(find ~/.clacky/skills/skill-add .clacky/skills/skill-add -name 'install_from_zip.rb' 2>/dev/null | head -1)" <zip_url> <slug>
```

Or simply look at the **Supporting Files** section at the bottom of this document — it confirms `scripts` exists — then construct the path from whichever skill location is active.

---

## Usage Modes

### 1. Install from Zip URL (Public Store)

```
/skill-add Install the "my-skill" skill from https://example.com/my-skill-1.0.0.zip
```

When the user provides a URL ending in `.zip`, run the installer script:

```bash
ruby "$(find ~/.clacky/skills/skill-add .clacky/skills/skill-add -name 'install_from_zip.rb' 2>/dev/null | head -1)" <zip_url> <slug>
```

- `<zip_url>` — the download URL provided by the user
- `<slug>` — the skill's directory name (e.g. `ui-ux-pro-max`); if the user didn't provide one, infer it from the URL filename by stripping version suffixes

The script will automatically:
- Download the zip archive (follows HTTP redirects)
- Extract and locate all `SKILL.md` files inside
- Copy skill directories to `.clacky/skills/` in the current project (overwrites existing)
- Report installed skills with descriptions

**Do NOT manually download or unzip files — the script handles everything.**

### 2. Interactive Creation Mode

```
/skill-add Brief description of what the skill should do
/skill-add Create a skill for database migrations
```

When the user provides a description (not a URL), create the skill through conversation:

1. **Understand the intent** from their description
2. **Ask focused questions** (up to 3):
   - What should we call this skill? (suggest a kebab-case name)
   - What inputs or arguments does it need?
   - Should it have helper scripts? (bash/ruby/python)
3. **Design and create** the skill structure:
   - `.clacky/skills/{skill-name}/SKILL.md` — valid YAML frontmatter + clear instructions
   - `.clacky/skills/{skill-name}/scripts/` — helper scripts if needed
4. **Confirm** by showing what was created and how to invoke it

**Example Interaction:**
```
User: /skill-add Create a skill for API testing with curl

Agent: I'll help you create an API testing skill. A couple of quick questions:

Q1: Should it support authentication (Bearer tokens, API keys)?
User: Yes, Bearer tokens

Q2: Should it include pre-built examples for GET, POST, PUT, DELETE?
User: Yes please

Agent: Creating skill...

Created:
✓ .clacky/skills/api-tester/SKILL.md
✓ .clacky/skills/api-tester/scripts/test_endpoint.sh

You can now use: /api-tester
```

### 3. Quick Start (No Arguments)

```
/skill-add
```

Ask the user what they want to build and offer concrete suggestions:
- Command runner
- Code analyzer
- File processor
- Data transformer
- Custom workflow

Guide them through creation with focused questions, then build it.

---

## Skill Structure Reference

### Minimal SKILL.md
```markdown
---
name: hello-world
description: Simple greeting skill
disable-model-invocation: false
user-invocable: true
---

# Hello World Skill

## Usage
Say "hello" or `/hello-world`

## Steps
1. Greet the user
2. Offer assistance
```

### Full-Featured SKILL.md
```markdown
---
name: db-migrate
description: Database migration helper with rollback support
disable-model-invocation: false
user-invocable: true
---

# Database Migration Helper

## Usage
`/db-migrate [action]`

Actions: `create` · `up` · `down` · `status`

## Steps
1. Parse the action from arguments
2. Run the appropriate script from `scripts/`
3. Report results and any errors
```

---

## Best Practices

1. **Naming**: kebab-case only (`api-tester`, `code-formatter`)
2. **Description**: concise and action-oriented; include trigger phrases
3. **Steps**: numbered and specific — the model should be able to follow them mechanically
4. **Scripts**: put complex logic in `scripts/` rather than inline instructions
5. **Examples**: always include at least one usage example

## Notes

- Skills install to `.clacky/skills/` in the current project
- Project skills override global skills (`~/.clacky/skills/`)
- Skill names: lowercase + hyphens only
- SKILL.md must have valid YAML frontmatter
- Scripts should be executable (`chmod +x`)
- Test after creation with `/skill-name`
