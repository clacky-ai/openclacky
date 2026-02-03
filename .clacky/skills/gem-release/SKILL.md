---
name: gem-release
description: Automates the complete process of releasing a new version of the openclacky Ruby gem
disable-model-invocation: false
user-invocable: true
---

# Gem Release Skill

This skill automates the complete process of releasing a new version of the openclacky Ruby gem.

## Overview

This skill handles the entire gem release workflow from version bumping to publishing on RubyGems and creating GitHub releases.

## Usage

To use this skill, simply say:
- "Release a new version"
- "Publish a new gem version"
- Use the command: `/gem-release`

## Process Steps

### 1. Pre-Release Checks
- Check for uncommitted changes in the working directory
- Verify all tests pass before proceeding
- Ensure the repository is in a clean state

### 2. Version Management
- Read current version from `lib/clacky/version.rb`
- Increment version number (typically patch version: x.y.z → x.y.z+1)
- Update the VERSION constant in the version file

### 3. Quality Assurance
- Run the full test suite with `bundle exec rspec`
- Ensure all 167+ tests pass
- Verify no regressions introduced

### 4. Build Process
- Build the gem using `gem build openclacky.gemspec`
- Generate the `.gem` file for distribution
- Handle any build warnings appropriately

### 5. Update Gemfile.lock and Verify CI

1. **Update Gemfile.lock**
   ```bash
   bundle install
   ```
   This ensures Gemfile.lock reflects the new version.

2. **Commit Gemfile.lock Changes**
   ```bash
   git add Gemfile.lock
   git commit -m "chore: update Gemfile.lock to v{version}"
   ```

3. **Push and Verify CI**
   ```bash
   git push origin main
   ```
   - Wait for CI pipeline to complete successfully
   - Verify all tests pass
   - If CI fails, fix issues before proceeding

4. **Proceed Only After CI Success**
   - If CI fails: stop, fix issues, and restart the release process
   - If CI passes: continue to build and publish

### 6. Build and Publish Gem

1. **Build the Gem**
   ```bash
   gem build openclacky.gemspec
   ```
   Generates `openclacky-{version}.gem` file.

2. **Publish to RubyGems.org**
   ```bash
   gem push openclacky-{version}.gem
   ```
   Verify successful publication.

3. **Create Git Tag and Push**
   ```bash
   git tag v{version}
   git push origin main --tags
   ```

4. **Verify Publication**
   - Check gem appears on RubyGems.org
   - Verify version information is correct

### 6. Documentation - CHANGELOG Writing Process

**Critical Step: Review Commits Before Writing CHANGELOG**

1. **Find Previous Version Tag**
   - Get the latest version tag (e.g., v0.6.3)
   - Use `git describe --tags --abbrev=0` or manually identify

2. **Gather All Commits Since Last Release**
   ```bash
   git log {previous_tag}..HEAD --oneline
   git diff {previous_tag}..HEAD --stat
   ```

3. **Analyze and Categorize Commits**
   - Review each commit message and its changes
   - Categorize into:
     - **Major Features**: User-visible functionality additions
     - **Improvements**: Performance, UX, architecture enhancements
     - **Bug Fixes**: Error corrections and issue resolutions
     - **Changes**: Breaking changes or significant refactoring
     - **Minor Details**: Small fixes, style changes, trivial updates

4. **Write CHANGELOG Entries**

   **Format for Significant Items:**
   ```
   ## [Version] - Date

   ### Added
   - Feature description (link to related commits)

   ### Improved
   - Enhancement description

   ### Fixed
   - Bug fix description

   ### Changed
   - Breaking change description
   ```

   **Format for Minor Items (group under "More"):**
   ```
   ### More
   - Minor fix 1
   - Minor fix 2
   ```

5. **Prioritization Rules**:
   - Place user-facing value at the top
   - Group related commits together
   - Skip very trivial commits (typos, minor formatting)
   - Use imperative mood ("Add" not "Added")

6. **Example CHANGELOG Section**:
   ```markdown
   ## [0.6.4] - 2026-02-03

   ### Added
   - Anthropic API support with full Claude model integration
   - ClaudeCode environment compatibility (ANTHROPIC_API_KEY support)

   ### Improved
   - API client architecture for multi-provider support
   - Config loading with source tracking

   ### Fixed
   - Handle absolute paths correctly in glob tool

   ### More
   - Update dependencies
   - Minor style adjustments
   ```

7. **Commit and Push Documentation Updates**
   - Commit CHANGELOG.md changes
   - Push to remote repository

### 7. Final Verification
- Confirm the gem appears on RubyGems.org
- Check that version information is correct
- Verify installation works for end users

## Commands Used

```bash
# Pre-release checks
git status --porcelain

# Run tests
bundle exec rspec

# Update Gemfile.lock
bundle install
git add Gemfile.lock
git commit -m "chore: update Gemfile.lock to vX.Y.Z"
git push origin main

# Build and publish gem
gem build openclacky.gemspec
gem push openclacky-X.Y.Z.gem

# Git operations
git add lib/clacky/version.rb
git commit -m "chore: bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin --tags
```

## File Locations

- Version file: `lib/clacky/version.rb`
- Gem specification: `openclacky.gemspec`
- Changelog: `CHANGELOG.md`
- Built gem: `openclacky-{version}.gem`

## Success Criteria

- All tests pass
- CI pipeline completes successfully
- Gemfile.lock updated and committed
- New version successfully published to RubyGems
- Git repository updated with version tag
- CHANGELOG.md updated with release notes
- No build or deployment errors

## Error Handling

- If tests fail, stop the process and report issues
- If CI fails after Gemfile.lock update, fix issues before proceeding
- If gem build fails, check gemspec configuration
- If git push fails, verify repository permissions
- If gem push fails, check RubyGems credentials

## Notes

- This skill follows semantic versioning
- Always update CHANGELOG.md as part of the release
- Verify RubyGems.org shows the new version after publication
- The search index on RubyGems may take a few minutes to update

## Dependencies

- Ruby development environment
- Git repository access
- RubyGems account with push permissions
- Bundle and RSpec for testing

## Version History

- Created: 2026-01-18
- Used for: openclacky gem releases
- Compatible with: Ruby gems following standard conventions

## User Experience Summary

This skill takes the complexity out of gem releases. Instead of remembering 8+ different commands and worrying about the correct order, you just say "release a new version" and the AI handles everything - from running tests to publishing on RubyGems. It's like having an experienced release engineer on your team who never forgets a step, always runs the tests first, and makes sure your changelog is updated. The whole process that used to take 15-20 minutes and multiple terminal windows now happens smoothly in one conversation, with clear feedback at each step so you know exactly what's happening.