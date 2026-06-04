#!/bin/bash
# uninstall.sh — OpenClacky uninstaller
# Generated from scripts/build/src/uninstall.sh.cc — DO NOT EDIT DIRECTLY

set -e

@include lib/colors.sh
@include lib/os.sh
@include lib/shell.sh
@include lib/gem.sh

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
