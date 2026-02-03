---
name: commit
description: Smart Git commit helper that analyzes changes and creates semantic commits
disable-model-invocation: false
user-invocable: true
---

# Smart Commit Skill

This skill helps users create well-structured, semantic git commits by analyzing changes and suggesting appropriate commit messages.

## Overview

This skill automates the process of reviewing git changes and creating meaningful, conventional commits following the semantic commit format (feat/fix/chore/test).

## Usage

To use this skill, simply say:
- "Help me commit my changes"
- "Create semantic commits"
- "Review and commit changes"
- Use the command: `/commit`

## Process Steps

### 1. Analyze Git Status

First, check the current git status to understand:
- What files have been modified, added, or deleted
- Which files are staged vs unstaged
- Overall state of the working directory

```bash
git status
git diff --stat
```

### 2. Review Changes in Detail

For each changed file, analyze:
- The nature of changes (new feature, bug fix, refactoring, tests, documentation)
- Scope of changes (which component/module)
- Impact level (minor tweak vs major change)

```bash
git diff <file>
```

### 3. Generate Commit Messages

Based on the analysis, generate commit messages following the conventional commit format:

**Format**: `<type>: <description>`

**Types**:
- `feat`: New features or functionality
- `fix`: Bug fixes
- `chore`: Routine tasks, maintenance, dependencies
- `test`: Adding or modifying tests
- `docs`: Documentation changes
- `refactor`: Code refactoring without changing functionality
- `style`: Code style changes (formatting, whitespace)
- `perf`: Performance improvements

**Guidelines**:
- Keep messages concise (ideally under 50 characters)
- Use imperative mood ("add feature" not "added feature")
- Don't end with a period
- Be specific but brief
- One logical change per commit

**Examples**:
- `feat: add user authentication`
- `fix: resolve memory leak in parser`
- `chore: update dependencies`
- `test: add unit tests for validator`
- `docs: update README installation steps`

### 4. Group Changes

Organize changes into logical commits:
- Group related changes together
- Separate features, fixes, and chores
- Keep commits atomic and focused
- Suggest the order of commits

### 5. Present Suggestions

Show the user:
- List of proposed commits
- Files included in each commit
- Commit message for each group
- Brief explanation of the grouping logic

Format:
```
Commit 1: feat: add login endpoint
  - lib/api/auth.rb
  - spec/api/auth_spec.rb

Commit 2: fix: resolve timeout in database connection
  - lib/database/connection.rb

Commit 3: chore: update rubocop configuration
  - .rubocop.yml
```

### 6. Get User Confirmation

Ask the user:
- Review the proposed commits
- Confirm if they want to proceed
- Allow modifications if needed
- Get explicit approval before committing

### 7. Execute Commits

For each approved commit:
```bash
# Stage specific files
git add <file1> <file2> ...

# Create commit with message
git commit -m "<type>: <description>"
```

Provide feedback after each commit:
- Confirm successful commit
- Show commit hash
- Display summary

### 8. Final Summary

After all commits:
- Show total number of commits created
- List all commit messages
- Suggest next steps (e.g., git push)

## Commands Used

```bash
# Check status
git status
git status --short

# View changes
git diff
git diff --stat
git diff <file>

# Stage files
git add <file>

# Create commit
git commit -m "message"

# View commit history
git log --oneline -n 5
```

## Workflow Example

```
User: /commit

AI:
1. Analyzing git status...
   Found 5 modified files

2. Reviewing changes...
   - lib/user.rb: New user registration feature
   - lib/auth.rb: Fix password validation bug
   - spec/user_spec.rb: Tests for user registration
   - spec/auth_spec.rb: Tests for auth fix
   - Gemfile: Updated dependencies

3. Proposed commits:

   Commit 1: feat: add user registration
     - lib/user.rb
     - spec/user_spec.rb

   Commit 2: fix: correct password validation logic
     - lib/auth.rb
     - spec/auth_spec.rb

   Commit 3: chore: update gem dependencies
     - Gemfile

   Do you want to proceed with these commits? (yes/no)

User: yes

AI:
✓ Commit 1 created (a1b2c3d): feat: add user registration
✓ Commit 2 created (e4f5g6h): fix: correct password validation logic
✓ Commit 3 created (i7j8k9l): chore: update gem dependencies

Summary: 3 commits created successfully!
Next steps: Review with 'git log' or push with 'git push'
```

## Best Practices

### Commit Message Rules
- Start with lowercase (except proper nouns)
- Use present tense imperative
- Be specific but concise
- Focus on "what" and "why", not "how"

### Commit Organization
- One logical change per commit
- Keep features separate from fixes
- Don't mix refactoring with new features
- Test files go with their related code changes

### When to Split Commits
- Multiple unrelated features
- Features and bug fixes mixed
- Code changes and config changes
- Different modules/components affected

### When to Combine Changes
- Related test and implementation
- Multiple files for same feature
- Complementary changes for same fix

## Error Handling

- **No changes detected**: Inform user and exit gracefully
- **Merge conflicts**: Warn user to resolve conflicts first
- **Detached HEAD**: Alert user about repository state
- **Uncommitted changes during conflict**: Suggest stashing or committing
- **Empty commit message**: Request user input for clarification

## Safety Features

- Always review changes before committing
- Require user confirmation before executing commits
- Show exactly which files will be in each commit
- Allow user to modify suggestions
- Never force commits without approval
- Preserve git history integrity

## Integration with Workflow

This skill works best:
- After completing a feature or fix
- Before pushing to remote
- During code review preparation
- When cleaning up messy commit history (use with `git reset` first)

## Notes

- This skill does NOT push commits (user controls when to push)
- Follows conventional commits specification
- Encourages atomic, well-documented commits
- Helps maintain clean git history
- Useful for both beginners and experienced developers

## Dependencies

- Git installed and configured
- Working directory is a git repository
- User has permissions to commit
- Changes exist to commit

## Version History

- Created: 2025-02-01
- Purpose: Improve commit quality and development workflow
- Compatible with: Any git repository
