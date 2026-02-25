#!/bin/bash
# OpenClacky Installation Script
# This script automatically detects your system and installs OpenClacky

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
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

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS=Linux;;
        Darwin*)    OS=macOS;;
        CYGWIN*)    OS=Windows;;
        MINGW*)     OS=Windows;;
        *)          OS=Unknown;;
    esac
    print_info "Detected OS: $OS"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Compare version strings
version_ge() {
    # Returns 0 (true) if $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Check Ruby version
check_ruby() {
    if command_exists ruby; then
        RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
        print_info "Found Ruby version: $RUBY_VERSION"

        if version_ge "$RUBY_VERSION" "3.1.0"; then
            print_success "Ruby version is compatible (>= 3.1.0)"
            return 0
        else
            print_warning "Ruby version $RUBY_VERSION is too old (need >= 3.1.0)"
            return 1
        fi
    else
        print_warning "Ruby is not installed"
        return 1
    fi
}

# Install via RubyGems
install_via_gem() {
    print_step "Installing via RubyGems..."

    if ! command_exists gem; then
        print_error "RubyGems is not available"
        return 1
    fi

    print_info "Installing OpenClacky gem..."
    gem install openclacky

    if [ $? -eq 0 ]; then
        print_success "OpenClacky installed successfully via gem!"
        return 0
    else
        print_error "Gem installation failed"
        return 1
    fi
}

# Suggest Ruby installation
suggest_ruby_installation() {
    print_step "Ruby Installation Options"
    echo ""

    if [ "$OS" = "macOS" ]; then
        print_info "Option 1: Use rbenv (Recommended)"
        echo "  brew install rbenv ruby-build"
        echo "  rbenv install 3.3.0"
        echo "  rbenv global 3.3.0"
        echo ""
        print_info "Option 2: Install Ruby via Homebrew"
        echo "  brew install ruby@3.3"
        echo "  export PATH=\"/usr/local/opt/ruby@3.3/bin:\$PATH\""

    elif [ "$OS" = "Linux" ]; then
        print_info "Option 1: Use rbenv"
        echo "  curl -fsSL https://github.com/rbenv/rbenv-installer/raw/main/bin/rbenv-installer | bash"
        echo "  rbenv install 3.3.0"
        echo "  rbenv global 3.3.0"
        echo ""
        print_info "Option 2: Use RVM"
        echo "  curl -sSL https://get.rvm.io | bash -s stable --ruby"
        echo ""
        print_info "Option 3: Use system package manager"
        echo "  # Ubuntu/Debian:"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install ruby-full"
        echo ""
        echo "  # Fedora:"
        echo "  sudo dnf install ruby ruby-devel"
    fi

    echo ""
    print_info "After installing Ruby, run this script again or use:"
    echo "  gem install openclacky"
}

# Main installation logic
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🤖 OpenClacky Installation Script                      ║"
    echo "║                                                           ║"
    echo "║   AI Agent CLI with Tool Use Capabilities                ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    detect_os

    # Strategy 1: Check Ruby and install via gem
    if check_ruby; then
        if install_via_gem; then
            show_post_install_info
            exit 0
        fi
    fi

    # Strategy 2: Suggest Ruby installation options
    print_error "Could not install OpenClacky automatically"
    echo ""
    suggest_ruby_installation
    echo ""

    print_info "For more information, visit: https://github.com/clacky-ai/open-clacky"
    exit 1
}

# Post-installation information
show_post_install_info() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   ✨ OpenClacky Installed Successfully!                   ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    print_step "Quick Start Guide:"
    echo ""
    print_info "1. Configure your API key:"
    echo "   openclacky config set"
    echo ""
    print_info "2. Create a new project:"
    echo "   openclacky /new <project-name>"
    echo ""
    print_info "3. Get help:"
    echo "   openclacky help"
    echo ""
    print_success "Happy coding! 🚀"
    echo ""
}

# Run main installation
main
