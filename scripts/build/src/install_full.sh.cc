#!/bin/bash
# install_full.sh — OpenClacky full installer (macOS + Linux, with Homebrew)
# Generated from scripts/build/src/install_full.sh.cc — DO NOT EDIT DIRECTLY

set -e

BRAND_NAME=""
BRAND_COMMAND=""
RESTORE_MIRRORS=false

@include lib/colors.sh
@include lib/os.sh
@include lib/shell.sh
@include lib/network.sh
@include lib/brew.sh
@include lib/mise.sh
@include lib/gem.sh

# --------------------------------------------------------------------------
# CN mirror config — gem, npm (persisted to dotfiles)
# --------------------------------------------------------------------------
configure_cn_mirrors() {
    [ "$USE_CN_MIRRORS" = true ] || return 0
    print_step "Configuring CN mirrors (permanent)..."

    # gem: ~/.gemrc
    configure_gem_source

    # npm: ~/.npmrc
    local npmrc="$HOME/.npmrc"
    if grep -q "${NPM_REGISTRY_URL}" "$npmrc" 2>/dev/null; then
        print_success "npm registry already set → ${NPM_REGISTRY_URL}"
    else
        [ -f "$npmrc" ] && [ ! -f "$HOME/.npmrc_clackybak" ] && cp "$npmrc" "$HOME/.npmrc_clackybak"
        if command_exists npm; then
            npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null && \
                print_success "npm registry → ${NPM_REGISTRY_URL}"
        else
            echo "registry=${NPM_REGISTRY_URL}" >> "$npmrc"
            print_success "npm registry → ${NPM_REGISTRY_URL} (pre-set)"
        fi
    fi

    echo ""
}

restore_mirrors() {
    print_step "Restoring original mirror settings..."

    # gem
    restore_gemrc

    # npm
    local npmrc="$HOME/.npmrc" npmrc_bak="$HOME/.npmrc_clackybak"
    if [ -f "$npmrc_bak" ]; then
        mv "$npmrc_bak" "$npmrc"; print_success "~/.npmrc restored from backup"
    elif [ -f "$npmrc" ]; then
        rm "$npmrc"; print_success "~/.npmrc removed"
    else
        print_info "~/.npmrc — nothing to restore"
    fi

    # mise node.mirror_url
    local mise_bin=""
    command_exists mise && mise_bin="mise"
    [ -x "$HOME/.local/bin/mise" ] && mise_bin="$HOME/.local/bin/mise"
    [ -n "$mise_bin" ] && "$mise_bin" settings unset node.mirror_url 2>/dev/null && \
        print_success "mise node.mirror_url unset"

    restore_homebrew_cn_mirrors

    echo ""
    print_success "Done. All mirror settings restored."
    echo ""
}

# --------------------------------------------------------------------------
# Ruby check
# --------------------------------------------------------------------------
check_ruby() {
    command_exists ruby || return 1
    local ver; ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    version_ge "$ver" "3.1.0" && { print_success "Ruby $ver — OK (>= 3.1.0)"; return 0; }
    print_warning "Ruby $ver too old (need >= 3.1.0)"; return 1
}

# --------------------------------------------------------------------------
# macOS: Homebrew + build deps + Ruby via mise
# --------------------------------------------------------------------------
install_macos_dependencies() {
    print_step "Installing macOS dependencies and Ruby..."
    echo ""

    configure_homebrew_cn_mirrors
    ensure_homebrew || return 1

    print_info "Installing build dependencies..."
    brew install openssl@3 libyaml gmp || { print_error "Failed to install build deps"; return 1; }
    print_success "Build dependencies installed"

    ensure_mise   || return 1
    install_ruby_via_mise || return 1
    check_ruby    || { print_error "Ruby installation verification failed"; return 1; }
}

# --------------------------------------------------------------------------
# Linux (Ubuntu/Debian): apt mirror + build deps + Ruby via mise
# --------------------------------------------------------------------------
install_ubuntu_dependencies() {
    print_step "Installing Ubuntu dependencies and Ruby..."
    echo ""

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Configuring apt mirror (Aliyun)..."
        local codename="${VERSION_CODENAME:-jammy}"
        local components="main restricted universe multiverse"
        local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
        if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
            local mirror_base="https://mirrors.aliyun.com/ubuntu-ports/"
        else
            local mirror_base="https://mirrors.aliyun.com/ubuntu/"
        fi
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror_base} ${codename} ${components}
deb ${mirror_base} ${codename}-updates ${components}
deb ${mirror_base} ${codename}-backports ${components}
deb ${mirror_base} ${codename}-security ${components}
EOF
        print_success "Aliyun apt mirror configured"
    fi

    sudo apt update || { print_error "apt update failed"; return 1; }
    sudo apt install -y build-essential libssl-dev libyaml-dev zlib1g-dev libgmp-dev git || \
        { print_error "Build deps install failed"; return 1; }
    print_success "Build dependencies installed"

    # WSL: auto-trust Windows system32 to suppress mise warnings
    export MISE_TRUSTED_CONFIG_PATHS="/mnt/c/Windows/system32"

    ensure_mise   || return 1
    install_ruby_via_mise || return 1
    check_ruby    || { print_error "Ruby installation verification failed"; return 1; }
}

# --------------------------------------------------------------------------
# gem install openclacky
# --------------------------------------------------------------------------
install_via_gem() {
    print_step "Installing via RubyGems..."
    command_exists gem  || { print_error "RubyGems not available"; return 1; }
    command_exists ruby || { print_error "Ruby not available"; return 1; }

    local ver; ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    version_ge "$ver" "3.1.0" || { print_error "Ruby $ver too old (>= 3.1.0 required)"; return 1; }

    setup_gem_home

    print_info "Installing ${DISPLAY_NAME}..."
    if gem install openclacky --no-document; then
        print_success "${DISPLAY_NAME} installed!"
        install_chrome_devtools_mcp
        return 0
    else
        print_error "gem install failed"; return 1
    fi
}

# --------------------------------------------------------------------------
# Optional: chrome-devtools-mcp (browser automation)
# --------------------------------------------------------------------------
install_chrome_devtools_mcp() {
    print_step "Installing chrome-devtools-mcp..."

    if ! command_exists npm; then
        local mise_bin=""
        command_exists mise && mise_bin="mise"
        [ -x "$HOME/.local/bin/mise" ] && mise_bin="$HOME/.local/bin/mise"
        if [ -n "$mise_bin" ]; then
            "$mise_bin" install node@22 >/dev/null 2>&1 || true
            "$mise_bin" use -g node@22  >/dev/null 2>&1 || true
            eval "$($mise_bin activate bash 2>/dev/null)" 2>/dev/null || true
        fi
    fi

    if ! command_exists npm; then
        print_warning "npm not found — browser automation unavailable"
        print_info "Install Node.js then run: npm install -g chrome-devtools-mcp"
        return 0
    fi

    if npm install -g chrome-devtools-mcp >/dev/null 2>&1; then
        print_success "chrome-devtools-mcp installed"
    else
        print_warning "chrome-devtools-mcp install failed"
        print_info "Run manually: npm install -g chrome-devtools-mcp"
    fi
}

# --------------------------------------------------------------------------
# Parse args
# --------------------------------------------------------------------------
parse_args() {
    for arg in "$0" "$@"; do
        case "$arg" in
            --brand-name=*)    BRAND_NAME="${arg#--brand-name=}"    ;;
            --command=*)       BRAND_COMMAND="${arg#--command=}"     ;;
            --restore-mirrors) RESTORE_MIRRORS=true                 ;;
        esac
    done
    DISPLAY_NAME="${BRAND_NAME:-OpenClacky}"
}

# --------------------------------------------------------------------------
# Brand setup
# --------------------------------------------------------------------------
setup_brand() {
    [ -z "$BRAND_NAME" ] && return 0
    local brand_file="${CLACKY_HOME:-$HOME/.clacky}/brand.yml"
    mkdir -p "${CLACKY_HOME:-$HOME/.clacky}"
    print_step "Configuring brand: $BRAND_NAME"
    cat > "$brand_file" <<YAML
product_name: "${BRAND_NAME}"
package_name: "${BRAND_COMMAND}"
YAML
    print_success "Brand config written to $brand_file"

    if [ -n "$BRAND_COMMAND" ]; then
        local bin_dir="$HOME/.local/bin"
        mkdir -p "$bin_dir"
        local wrapper="$bin_dir/$BRAND_COMMAND"
        cat > "$wrapper" <<WRAPPER
#!/bin/sh
exec openclacky "\$@"
WRAPPER
        chmod +x "$wrapper"
        print_success "Wrapper installed: $wrapper"
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *) print_warning "Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
        esac
    fi
}

# --------------------------------------------------------------------------
# Post-install info
# --------------------------------------------------------------------------
show_post_install_info() {
    local cmd="${BRAND_COMMAND:-openclacky}"
    echo ""
    echo -e "  ${GREEN}${DISPLAY_NAME} installed successfully!${NC}"
    echo ""
    echo "  Reload your shell:"
    echo -e "    ${YELLOW}source ${SHELL_RC}${NC}"
    echo ""
    echo -e "  ${GREEN}Web UI${NC} (recommended):"
    echo "    $cmd server  →  http://localhost:7070"
    echo ""
    echo -e "  ${GREEN}Terminal${NC}:"
    echo "    $cmd"
    echo ""
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    parse_args "$@"

    [ "$RESTORE_MIRRORS" = true ] && { restore_mirrors; exit 0; }

    echo ""
    echo "${DISPLAY_NAME} Installation"
    echo ""

    detect_os
    detect_shell
    detect_network_region
    configure_cn_mirrors

    assert_supported_os "Please install Ruby manually and run: gem install openclacky"

    if [ "$OS" = "macOS" ]; then
        install_macos_dependencies || { print_error "Failed to install dependencies"; exit 1; }
    elif [ "$OS" = "Linux" ]; then
        install_ubuntu_dependencies || { print_error "Failed to install dependencies"; exit 1; }
    fi

    install_via_gem && { setup_brand; show_post_install_info; exit 0; }
    print_error "Failed to install ${DISPLAY_NAME}"; exit 1
}

main "$@"
