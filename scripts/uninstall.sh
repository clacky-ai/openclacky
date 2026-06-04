#!/bin/bash
# uninstall.sh — OpenClacky uninstaller
# Generated from scripts/build/src/uninstall.sh.cc — DO NOT EDIT DIRECTLY

set -e


# ---[ @include lib/colors.sh ]---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_step()    { echo -e "\n${BLUE}==>${NC} $1"; }


# ---[ @include lib/os.sh ]---

# Sets OS (macOS | Linux | Windows | Unknown) and DISTRO (ubuntu | debian | …)
detect_os() {
    case "$(uname -s)" in
        Linux*)  OS=Linux  ;;
        Darwin*) OS=macOS  ;;
        CYGWIN*) OS=Windows ;;
        MINGW*)  OS=Windows ;;
        *)       OS=Unknown ;;
    esac
    print_info "Detected OS: $OS"

    if [ "$OS" = "Linux" ] && [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO=$ID
        print_info "Detected Linux distribution: $DISTRO"
    else
        DISTRO=unknown
    fi
}

# Returns 0 if the given command is on PATH
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Boolean helpers — use these in business logic instead of inline string comparisons
is_macos()     { [ "$OS" = "macOS" ]; }
is_linux_apt() { [ "$OS" = "Linux" ] && { [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; }; }

# Returns 0 (true) if $1 >= $2  (semantic version comparison)
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# Assert that the current OS/distro is supported (macOS or Ubuntu/Debian).
# Optional $1: hint message printed on failure (e.g. manual install instructions).
# Exits with code 1 on unsupported OS or distro.
assert_supported_os() {
    local hint="${1:-}"
    if [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            return 0
        fi
        print_error "Unsupported Linux distribution: $DISTRO"
        [ -n "$hint" ] && print_info "$hint"
        exit 1
    elif [ "$OS" = "macOS" ]; then
        return 0
    else
        print_error "Unsupported OS: $OS"
        [ -n "$hint" ] && print_info "$hint"
        exit 1
    fi
}


# ---[ @include lib/shell.sh ]---

# Sets CURRENT_SHELL (zsh | bash | fish) and SHELL_RC (path to rc file)
detect_shell() {
    local shell_name
    shell_name=$(basename "$SHELL")

    case "$shell_name" in
        zsh)
            CURRENT_SHELL="zsh"
            SHELL_RC="$HOME/.zshrc"
            ;;
        fish)
            CURRENT_SHELL="fish"
            SHELL_RC="$HOME/.config/fish/config.fish"
            ;;
        bash)
            CURRENT_SHELL="bash"
            # macOS uses ~/.bash_profile; Linux uses ~/.bashrc
            if is_macos; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
        *)
            CURRENT_SHELL="bash"
            SHELL_RC="$HOME/.bashrc"
            ;;
    esac

    print_info "Detected shell: $CURRENT_SHELL (rc file: $SHELL_RC)"
}


# ---[ @include lib/gem.sh ]---

configure_gem_source() {
    local gemrc="$HOME/.gemrc"

    if [ "$USE_CN_MIRRORS" = true ]; then
        if grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
            print_success "gem source already → ${CN_RUBYGEMS_URL}"
        else
            [ -f "$gemrc" ] && mv "$gemrc" "$HOME/.gemrc_clackybak"
            cat > "$gemrc" <<GEMRC
:sources:
  - ${CN_RUBYGEMS_URL}
GEMRC
            print_success "gem source → ${CN_RUBYGEMS_URL}"
        fi
    else
        if [ -f "$gemrc" ] && grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
            if [ -f "$HOME/.gemrc_clackybak" ]; then
                mv "$HOME/.gemrc_clackybak" "$gemrc"
                print_info "gem source restored from backup"
            else
                rm "$gemrc"
                print_info "gem source restored to default"
            fi
        fi
    fi
}

restore_gemrc() {
    local gemrc="$HOME/.gemrc"
    local gemrc_bak="$HOME/.gemrc_clackybak"
    if [ -f "$gemrc_bak" ]; then
        mv "$gemrc_bak" "$gemrc"
        print_success "~/.gemrc restored from backup"
    elif [ -f "$gemrc" ]; then
        rm "$gemrc"
        print_success "~/.gemrc removed"
    else
        print_info "~/.gemrc — nothing to restore"
    fi
}

# --------------------------------------------------------------------------
# Redirect GEM_HOME to user dir when system Ruby gem dir is not writable
# --------------------------------------------------------------------------
setup_gem_home() {
    local gem_dir
    gem_dir=$(gem environment gemdir 2>/dev/null || true)
    [ -w "$gem_dir" ] && return 0

    local ruby_api
    ruby_api=$(ruby -e 'puts RbConfig::CONFIG["ruby_version"]' 2>/dev/null)
    export GEM_HOME="$HOME/.gem/ruby/${ruby_api}"
    export GEM_PATH="$HOME/.gem/ruby/${ruby_api}"
    export PATH="$HOME/.gem/ruby/${ruby_api}/bin:$PATH"
    print_info "System Ruby detected — gems will install to ~/.gem/ruby/${ruby_api}"

    if [ -n "$SHELL_RC" ] && ! grep -q "GEM_HOME" "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# Ruby user gem dir (added by openclacky installer)"
            echo "export GEM_HOME=\"\$HOME/.gem/ruby/${ruby_api}\""
            echo "export GEM_PATH=\"\$HOME/.gem/ruby/${ruby_api}\""
            echo "export PATH=\"\$HOME/.gem/ruby/${ruby_api}/bin:\$PATH\""
        } >> "$SHELL_RC"
        print_info "GEM_HOME written to $SHELL_RC"
    fi
}

restore_gem_home() {
    [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] || return 0
    grep -q "GEM_HOME" "$SHELL_RC" 2>/dev/null || return 0
    # Remove the block written by setup_gem_home (comment + 3 export lines)
    local tmp
    tmp=$(mktemp)
    grep -v "# Ruby user gem dir (added by openclacky installer)" "$SHELL_RC" \
        | grep -v "export GEM_HOME=" \
        | grep -v "export GEM_PATH=" \
        | grep -v "/.gem/ruby/" \
        > "$tmp" && mv "$tmp" "$SHELL_RC"
    print_success "GEM_HOME removed from $SHELL_RC"
}


# --------------------------------------------------------------------------
# Load brand config
# --------------------------------------------------------------------------
BRAND_NAME=""
BRAND_COMMAND=""
DISPLAY_NAME="OpenClacky"

load_brand() {
    local brand_file="$HOME/.clacky/brand.yml"
    [ -f "$brand_file" ] || return 0
    BRAND_NAME=$(awk -F': ' '/^product_name:/{gsub(/^"|"$/, "", $2); gsub(/^ +| +$/, "", $2); print $2}' "$brand_file") || true
    BRAND_COMMAND=$(awk -F': ' '/^package_name:/{gsub(/^"|"$/, "", $2); gsub(/^ +| +$/, "", $2); print $2}' "$brand_file") || true
    if [ -n "$BRAND_NAME" ]; then DISPLAY_NAME="$BRAND_NAME"; fi
}

check_installation() {
    command_exists clacky || command_exists openclacky && return 0
    [ -n "$BRAND_COMMAND" ] && command_exists "$BRAND_COMMAND" && return 0
    return 1
}

uninstall_gem() {
    command_exists gem || return 1
    if gem list -i openclacky >/dev/null 2>&1; then
        print_step "Uninstalling via RubyGems..."
        gem uninstall openclacky -x
    else
        print_info "Gem 'openclacky' not found (already removed)"
    fi
}

remove_brand() {
    [ -z "$BRAND_COMMAND" ] && return 0
    local clacky_bin dir
    clacky_bin=$(command -v openclacky 2>/dev/null || true)
    [ -z "$clacky_bin" ] && return 0
    dir=$(dirname "$clacky_bin")
    if [ -f "$dir/$BRAND_COMMAND" ]; then
        rm -f "$dir/$BRAND_COMMAND"
        print_success "Brand wrapper removed: $dir/$BRAND_COMMAND"
    fi
}

remove_config() {
    local config_dir="$HOME/.clacky"
    [ -d "$config_dir" ] || return 0
    print_warning "Configuration directory found: $config_dir"
    read -r -p "Remove configuration files (including API keys)? [y/N] " reply
    if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
        rm -rf "$config_dir"
        print_success "Configuration removed"
    else
        print_info "Configuration preserved at: $config_dir"
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    load_brand
    detect_shell

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo -e "║   🗑️  ${DISPLAY_NAME} Uninstallation                     ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    if ! check_installation; then
        print_warning "${DISPLAY_NAME} does not appear to be installed"
        echo ""; exit 0
    fi

    remove_brand
    uninstall_gem || print_warning "gem command not found, skipping gem uninstall"
    print_success "${DISPLAY_NAME} uninstalled successfully"
    restore_gemrc
    restore_gem_home
    remove_config

    echo ""
    print_success "Uninstallation complete!"
    print_info "Thank you for using ${DISPLAY_NAME} 👋"
    echo ""
}

main
