#!/bin/bash
# release.sh — openclacky gem release automation
#
# Usage:
#   bash release.sh <version> [--prerelease] [--update-latest]
#
# Examples:
#   bash release.sh 1.0.6                           # stable release
#   bash release.sh 1.0.6 --dry-run                 # preview without executing
#   bash release.sh 2.0.0.beta.1 --prerelease       # pre-release, skip latest.txt
#   bash release.sh 2.0.0.rc1 --prerelease --update-latest  # pre-release, update latest.txt
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - coscli installed at /usr/local/bin/coscli with ~/.cos.yaml
#   - RubyGems credentials configured (gem push)

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✗${NC}  $1" >&2; }
step()    { echo -e "\n${CYAN}▶ Step $1:${NC} $2\n"; }
die()     { error "$1"; exit 1; }

# ── Parse args ──────────────────────────────────────────────────────────
VERSION=""
PRERELEASE=false
UPDATE_LATEST=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerelease)    PRERELEASE=true; UPDATE_LATEST=false ;;
        --update-latest) UPDATE_LATEST=true ;;
        --dry-run)       DRY_RUN=true ;;
        --help|-h)
            echo "Usage: bash release.sh <version> [--prerelease] [--update-latest] [--dry-run]"
            exit 0
            ;;
        -*)              die "Unknown option: $1" ;;
        *)               VERSION="$1" ;;
    esac
    shift
done

[[ -z "$VERSION" ]] && die "Version argument required. Usage: bash release.sh <version>"

# ── Resolve paths ───────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository"
cd "$REPO_ROOT"

VERSION_FILE="lib/clacky/version.rb"
GEMSPEC="openclacky.gemspec"
CHANGELOG="CHANGELOG.md"
GEM_FILE="openclacky-${VERSION}.gem"
OSS_BUCKET="cos://clackyai-1258723534"

[[ -f "$VERSION_FILE" ]] || die "Version file not found: $VERSION_FILE"
[[ -f "$GEMSPEC" ]]      || die "Gemspec not found: $GEMSPEC"

CURRENT_VERSION=$(ruby -ne 'puts $1 if /VERSION\s*=\s*"([^"]+)"/' "$VERSION_FILE")
info "Current version: ${CURRENT_VERSION}"
info "Target version:  ${VERSION}"
info "Pre-release:     ${PRERELEASE}"
info "Update latest:   ${UPDATE_LATEST}"
info "Dry run:         ${DRY_RUN}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN mode — no changes will be made"
    echo ""
fi

# ── Helper: run or preview ──────────────────────────────────────────────
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $*"
    else
        "$@"
    fi
}

# ════════════════════════════════════════════════════════════════════════
# Step 1: Pre-release checks
# ════════════════════════════════════════════════════════════════════════
step 1 "Pre-release checks"

if [[ -n "$(git status --porcelain)" ]]; then
    die "Working directory is not clean. Commit or stash changes first."
fi
success "Working directory is clean"

BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
    warn "Not on main branch (currently on '${BRANCH}')"
fi

command -v gh    >/dev/null 2>&1 || die "gh CLI not found. Install with: brew install gh"
command -v coscli >/dev/null 2>&1 || die "coscli not found. Install at /usr/local/bin/coscli"
success "Required tools available (gh, coscli)"

# ════════════════════════════════════════════════════════════════════════
# Step 2: Run tests
# ════════════════════════════════════════════════════════════════════════
step 2 "Running test suite"

if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[dry-run]${NC} bundle exec rspec"
else
    bundle exec rspec || die "Tests failed — aborting release"
fi
success "All tests passed"

# ════════════════════════════════════════════════════════════════════════
# Step 3: Bump version
# ════════════════════════════════════════════════════════════════════════
step 3 "Bumping version to ${VERSION}"

run sed -i '' "s/VERSION = \"${CURRENT_VERSION}\"/VERSION = \"${VERSION}\"/" "$VERSION_FILE"

if [[ "$DRY_RUN" != true ]]; then
    grep -q "VERSION = \"${VERSION}\"" "$VERSION_FILE" || die "Version bump failed"
fi
success "Updated ${VERSION_FILE}"

# ════════════════════════════════════════════════════════════════════════
# Step 4: Update Gemfile.lock
# ════════════════════════════════════════════════════════════════════════
step 4 "Updating Gemfile.lock"

run bundle install --quiet
success "Gemfile.lock updated"

# ════════════════════════════════════════════════════════════════════════
# Step 5: Commit version bump
# ════════════════════════════════════════════════════════════════════════
step 5 "Committing version bump"

run git add "$VERSION_FILE" Gemfile.lock
run git commit -m "chore: bump version to ${VERSION}"
success "Version bump committed"

# ════════════════════════════════════════════════════════════════════════
# Step 6: Push and wait for CI
# ════════════════════════════════════════════════════════════════════════
step 6 "Pushing to origin and checking CI"

run git push origin "$BRANCH"
success "Pushed to origin/${BRANCH}"

if [[ "$DRY_RUN" != true ]]; then
    info "Waiting for CI to complete (this may take a few minutes)..."
    if gh run list --branch "$BRANCH" --limit 1 --json status -q '.[0].status' 2>/dev/null | grep -q "completed"; then
        success "CI already completed"
    else
        gh run watch --exit-status 2>/dev/null || warn "Could not watch CI run — verify manually at GitHub Actions"
    fi
fi

# ════════════════════════════════════════════════════════════════════════
# Step 7: Build gem
# ════════════════════════════════════════════════════════════════════════
step 7 "Building gem"

run gem build "$GEMSPEC"

if [[ "$DRY_RUN" != true ]]; then
    [[ -f "$GEM_FILE" ]] || die "Gem file not found: $GEM_FILE"
fi
success "Built ${GEM_FILE}"

# ════════════════════════════════════════════════════════════════════════
# Step 8: Publish to RubyGems
# ════════════════════════════════════════════════════════════════════════
step 8 "Publishing to RubyGems"

run gem push "$GEM_FILE"
success "Published to RubyGems"

# ════════════════════════════════════════════════════════════════════════
# Step 9: Git tag
# ════════════════════════════════════════════════════════════════════════
step 9 "Creating git tag v${VERSION}"

run git tag "v${VERSION}"
run git push origin --tags
success "Tag v${VERSION} pushed"

# ════════════════════════════════════════════════════════════════════════
# Step 10: GitHub Release
# ════════════════════════════════════════════════════════════════════════
step 10 "Creating GitHub Release"

RELEASE_NOTES_FILE="/tmp/release_notes_${VERSION}.md"

if [[ "$DRY_RUN" != true ]]; then
    if [[ -f "$CHANGELOG" ]]; then
        # Extract section for this version from CHANGELOG
        awk "/^## \\[${VERSION}\\]/{found=1; next} /^## \\[/{if(found) exit} found{print}" "$CHANGELOG" > "$RELEASE_NOTES_FILE"
        if [[ ! -s "$RELEASE_NOTES_FILE" ]]; then
            echo "Release v${VERSION}" > "$RELEASE_NOTES_FILE"
            warn "No CHANGELOG entry found for ${VERSION} — using placeholder"
        fi
    else
        echo "Release v${VERSION}" > "$RELEASE_NOTES_FILE"
        warn "CHANGELOG.md not found — using placeholder"
    fi
fi

if [[ "$PRERELEASE" == true ]]; then
    run gh release create "v${VERSION}" \
        --title "v${VERSION}" \
        --notes-file "$RELEASE_NOTES_FILE" \
        --prerelease \
        "$GEM_FILE"
else
    run gh release create "v${VERSION}" \
        --title "v${VERSION}" \
        --notes-file "$RELEASE_NOTES_FILE" \
        --latest \
        "$GEM_FILE"
fi
success "GitHub Release created"

# ════════════════════════════════════════════════════════════════════════
# Step 11: Upload to OSS CDN
# ════════════════════════════════════════════════════════════════════════
step 11 "Syncing to Tencent Cloud OSS"

run coscli cp "$GEM_FILE" "${OSS_BUCKET}/openclacky/${GEM_FILE}"
success "Uploaded ${GEM_FILE} to OSS"

if [[ "$UPDATE_LATEST" == true ]]; then
    if [[ "$DRY_RUN" != true ]]; then
        echo "${VERSION}" > /tmp/latest.txt
    fi
    run coscli cp /tmp/latest.txt "${OSS_BUCKET}/openclacky/latest.txt"
    success "Updated latest.txt → ${VERSION}"

    if [[ "$DRY_RUN" != true ]]; then
        VERIFY=$(curl -fsSL https://oss.1024code.com/openclacky/latest.txt 2>/dev/null || echo "FAILED")
        if [[ "$VERIFY" == "$VERSION" ]]; then
            success "Verified latest.txt = ${VERSION}"
        else
            warn "latest.txt verification returned: ${VERIFY}"
        fi
    fi
else
    info "Skipping latest.txt update (pre-release or not requested)"
fi

# ════════════════════════════════════════════════════════════════════════
# Step 12: Sync scripts to OSS
# ════════════════════════════════════════════════════════════════════════
step 12 "Rebuilding and syncing scripts to OSS"

run bash scripts/build/build.sh

if [[ "$DRY_RUN" != true ]]; then
    for script in scripts/*.sh scripts/*.ps1; do
        [[ -f "$script" ]] || continue
        coscli cp "$script" "${OSS_BUCKET}/clacky-ai/openclacky/main/scripts/$(basename "$script")"
        success "Uploaded $(basename "$script")"
    done
else
    echo -e "  ${YELLOW}[dry-run]${NC} Upload scripts/*.sh and scripts/*.ps1 to OSS"
fi
success "Scripts synced to OSS"

# ════════════════════════════════════════════════════════════════════════
# Step 13: Cleanup
# ════════════════════════════════════════════════════════════════════════
step 13 "Cleanup"

[[ -f "$GEM_FILE" ]] && rm -f "$GEM_FILE" && info "Removed ${GEM_FILE}"
[[ -f "$RELEASE_NOTES_FILE" ]] && rm -f "$RELEASE_NOTES_FILE"
[[ -f "/tmp/latest.txt" ]] && rm -f /tmp/latest.txt

# ════════════════════════════════════════════════════════════════════════
# Done
# ════════════════════════════════════════════════════════════════════════
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                                                           ║"
echo -e "║   ${GREEN}🎉  v${VERSION} released successfully!${NC}                     ║"
echo "║                                                           ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  📦 RubyGems:  rubygems.org/gems/openclacky              ║"
echo "║  🏷️  GitHub:    github.com/clacky-ai/openclacky/releases  ║"
echo "║  ☁️  OSS CDN:   oss.1024code.com/openclacky/              ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
