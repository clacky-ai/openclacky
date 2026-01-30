#!/bin/bash
# OpenClacky Uninstallation Script
# This script removes OpenClacky from your system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if OpenClacky is installed
check_installation() {
    if command_exists clacky || command_exists openclacky; then
        return 0
    else
        return 1
    fi
}

# Uninstall via Homebrew
uninstall_homebrew() {
    if command_exists brew; then
        if brew list openclacky >/dev/null 2>&1; then
            print_step "Uninstalling via Homebrew..."
            brew uninstall openclacky
            
            # Optionally untap
            if brew tap | grep -q "clacky-ai/openclacky"; then
                read -p "$(echo -e ${YELLOW}?${NC}) Remove Homebrew tap (clacky-ai/openclacky)? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    brew untap clacky-ai/openclacky
                    print_success "Tap removed"
                fi
            fi
            
            return 0
        fi
    fi
    return 1
}

# Uninstall via gem
uninstall_gem() {
    if command_exists gem; then
        if gem list -i openclacky >/dev/null 2>&1; then
            print_step "Uninstalling via RubyGems..."
            gem uninstall openclacky -x
            return 0
        fi
    fi
    return 1
}

# Remove configuration files
remove_config() {
    CONFIG_DIR="$HOME/.clacky"
    
    if [ -d "$CONFIG_DIR" ]; then
        print_warning "Configuration directory found: $CONFIG_DIR"
        read -p "$(echo -e ${YELLOW}?${NC}) Remove configuration files (including API keys)? [y/N] " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            print_success "Configuration removed"
        else
            print_info "Configuration preserved at: $CONFIG_DIR"
        fi
    fi
}

# Main uninstallation
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🗑️  OpenClacky Uninstallation                          ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    if ! check_installation; then
        print_warning "OpenClacky does not appear to be installed"
        exit 0
    fi
    
    UNINSTALLED=false
    
    # Try Homebrew first
    if uninstall_homebrew; then
        UNINSTALLED=true
    fi
    
    # Try gem
    if uninstall_gem; then
        UNINSTALLED=true
    fi
    
    if [ "$UNINSTALLED" = false ]; then
        print_error "Could not automatically uninstall OpenClacky"
        print_info "You may need to uninstall manually:"
        echo "  - Via Homebrew: brew uninstall openclacky"
        echo "  - Via RubyGems: gem uninstall openclacky"
        exit 1
    fi
    
    print_success "OpenClacky uninstalled successfully"
    
    # Ask about config removal
    remove_config
    
    echo ""
    print_success "Uninstallation complete!"
    print_info "Thank you for using OpenClacky 👋"
    echo ""
}

main
