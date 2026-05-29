#!/bin/bash
# install.sh — OpenClacky installer
# Generated from scripts/build/src/install.sh.cc — DO NOT EDIT DIRECTLY

set -e

# Brand configuration (populated by --brand-name / --command flags)
BRAND_NAME=""
BRAND_COMMAND=""

@include lib/colors.sh
@include lib/os.sh
@include lib/shell.sh
@include lib/network.sh
@include lib/apt.sh

@include lib/gem.sh

# --------------------------------------------------------------------------
# Ensure Ruby >= 2.6 is available
# macOS: uses system Ruby or user-installed Ruby
# Linux: tries apt first; if missing or too old, prints manual install hint
# --------------------------------------------------------------------------
check_ruby() {
    command_exists ruby || return 1
    local ver; ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    version_ge "$ver" "2.6.0" && { print_success "Ruby $ver — OK"; return 0; }
    print_warning "Ruby $ver too old (need >= 2.6.0)"; return 1
}

ensure_ruby() {
    print_step "Checking Ruby..."
    check_ruby && return 0

    if is_linux_apt; then
        print_info "Installing Ruby via apt..."
        apt_get_run install -y ruby ruby-dev 2>/dev/null && check_ruby && return 0
        print_warning "apt Ruby install failed or version too old"
    fi

    return 1
}

# --------------------------------------------------------------------------
# gem install openclacky
# --------------------------------------------------------------------------
install_via_gem() {
    print_step "Installing ${DISPLAY_NAME} via gem..."
    configure_gem_source
    setup_gem_home

    local target source_args=()
    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Fetching latest version from OSS..."
        local cn_version; cn_version=$(curl -fsSL "$CN_GEM_LATEST_URL" | tr -d '[:space:]')
        print_info "Latest version: ${cn_version}"
        local gem_url="${CN_GEM_BASE_URL}/openclacky-${cn_version}.gem"
        local gem_file="/tmp/openclacky-${cn_version}.gem"
        print_info "Downloading openclacky-${cn_version}.gem..."
        curl -fsSL "$gem_url" -o "$gem_file"
        target="$gem_file"
        source_args=(--source "$CN_RUBYGEMS_URL")
    else
        target="openclacky"
    fi

    # macOS system Ruby 2.6 has a buggy gem resolver that fails on rouge 4.x.
    # Pre-install a 2.6-compatible rouge to avoid resolver failure.
    local ruby_ver; ruby_ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    if [[ "$ruby_ver" == 2.6.* ]]; then
        print_warning "Ruby 2.6 detected — pinning rouge 3.30.0 first"
        gem install rouge -v 3.30.0 --no-document "${source_args[@]}" || { print_error "gem install rouge failed"; return 1; }
    fi

    if gem install "$target" --no-document "${source_args[@]}"; then
        print_success "${DISPLAY_NAME} installed successfully!"
        return 0
    fi

    print_error "gem install failed"; return 1
}

# --------------------------------------------------------------------------
# Parse CLI args
# --------------------------------------------------------------------------
parse_args() {
    for arg in "$0" "$@"; do
        case "$arg" in
            --brand-name=*) BRAND_NAME="${arg#--brand-name=}" ;;
            --command=*)    BRAND_COMMAND="${arg#--command=}"  ;;
        esac
    done
    DISPLAY_NAME="${BRAND_NAME:-OpenClacky}"
}

# --------------------------------------------------------------------------
# Brand wrapper setup
# --------------------------------------------------------------------------
setup_brand() {
    [ -z "$BRAND_NAME" ] && return 0
    local clacky_dir="$HOME/.clacky"
    local brand_file="$clacky_dir/brand.yml"
    mkdir -p "$clacky_dir"
    print_step "Configuring brand: $BRAND_NAME"
    cat > "$brand_file" <<YAML
product_name: "${BRAND_NAME}"
package_name: "${BRAND_COMMAND}"
YAML
    print_success "Brand config written to $brand_file"

    if [ -n "$BRAND_COMMAND" ]; then
        local clacky_bin bin_dir
        clacky_bin=$(command -v openclacky 2>/dev/null || true)
        if [ -n "$clacky_bin" ]; then
            bin_dir=$(dirname "$clacky_bin")
        else
            print_warning "openclacky binary not found in PATH; skipping wrapper install"
            return 0
        fi
        local wrapper="$bin_dir/$BRAND_COMMAND"
        cat > "$wrapper" <<WRAPPER
#!/bin/sh
exec openclacky "\$@"
WRAPPER
        chmod +x "$wrapper"
        print_success "Wrapper installed: $wrapper"
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
    echo "    $cmd server"
    echo "    Open http://localhost:7070"
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
    echo ""
    echo "${DISPLAY_NAME} Installation"
    echo ""

    detect_os
    detect_shell
    detect_network_region

    assert_supported_os "Please install Ruby >= 2.6.0 manually and run: gem install openclacky"

    if [ "$OS" = "Linux" ]; then
        setup_apt_mirror
    fi

    ensure_ruby  || { print_error "Could not install a compatible Ruby"; exit 1; }
    install_via_gem && { setup_brand; show_post_install_info; exit 0; }
    print_error "Failed to install ${DISPLAY_NAME}"; exit 1
}

main "$@"
