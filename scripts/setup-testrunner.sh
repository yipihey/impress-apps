#!/bin/bash
#
# setup-testrunner.sh
#
# Sets up the test user account with all development tools needed
# to run UI tests for impress-apps.
#
# Run this script in the testrunner account Terminal:
#   cd ~/Projects/impress-apps && ./scripts/setup-testrunner.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() {
    echo -e "\n${BLUE}==>${NC} ${1}"
}

print_success() {
    echo -e "${GREEN}✓${NC} ${1}"
}

print_skip() {
    echo -e "${YELLOW}→${NC} ${1} (already installed)"
}

REPO_DIR="$HOME/Projects/impress-apps"

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}  testrunner Setup Script${NC}"
echo -e "${BLUE}================================${NC}"

# 1. Accept Xcode license
print_step "Checking Xcode license..."
if ! xcodebuild -checkFirstLaunchStatus 2>/dev/null; then
    sudo xcodebuild -license accept
    print_success "Xcode license accepted"
else
    print_skip "Xcode license"
fi

# 2. Install Homebrew
print_step "Checking Homebrew..."
if ! command -v brew &> /dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to PATH
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
    print_success "Homebrew installed"
else
    print_skip "Homebrew"
fi

# Ensure brew is in PATH for this session
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

# 3. Install Rust
print_step "Checking Rust..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    print_success "Rust installed"
else
    print_skip "Rust"
fi

# Ensure cargo is in PATH for this session
source "$HOME/.cargo/env" 2>/dev/null || true

# 4. Install XcodeGen
print_step "Checking XcodeGen..."
if ! command -v xcodegen &> /dev/null; then
    brew install xcodegen
    print_success "XcodeGen installed"
else
    print_skip "XcodeGen"
fi

# 5. Build Rust frameworks
print_step "Building Rust frameworks..."
cd "$REPO_DIR"

if [ -f "./apps/imprint/build-rust.sh" ]; then
    echo "  Building imprint-core..."
    ./apps/imprint/build-rust.sh
    print_success "imprint-core built"
fi

if [ -f "./apps/implore/build-rust.sh" ]; then
    echo "  Building implore-core..."
    ./apps/implore/build-rust.sh
    print_success "implore-core built"
fi

# 6. Generate Xcode projects
print_step "Generating Xcode projects..."

if [ -f "./apps/imprint/project.yml" ]; then
    cd "$REPO_DIR/apps/imprint"
    xcodegen generate
    print_success "imprint.xcodeproj generated"
fi

if [ -f "./apps/implore/project.yml" ]; then
    cd "$REPO_DIR/apps/implore"
    xcodegen generate
    print_success "implore.xcodeproj generated"
fi

cd "$REPO_DIR"

# 7. Set up SSH key for passwordless access
print_step "Setting up SSH key..."
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "testrunner@localhost"

    # Add to own authorized_keys for localhost SSH
    cat "$HOME/.ssh/id_ed25519.pub" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"

    print_success "SSH key generated and added to authorized_keys"
else
    print_skip "SSH key"
fi

# Done
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Enable Remote Login (SSH) if not already:"
echo "   System Settings → General → Sharing → Remote Login → ON"
echo ""
echo "2. From your MAIN account (tabel), copy your SSH key:"
echo "   ssh-copy-id testrunner@localhost"
echo ""
echo "3. Test SSH from main account:"
echo "   ssh testrunner@localhost 'echo works'"
echo ""
echo "4. Run tests from main account:"
echo "   ./scripts/start-ui-tests.sh"
echo ""
echo "Keep this account logged in (screen can be locked)."
