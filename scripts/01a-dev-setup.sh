#!/bin/bash
# =============================================================================
# 01a-dev-setup.sh — Run as the admin user, after 01-admin-setup.sh
#
# Installs development tools on the admin account:
#   1. GitHub CLI (gh)
#   2. Claude Code CLI
#   3. Google Workspace CLI (gws) + Google Cloud SDK (gcloud)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Pre-flight checks -------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
    error "This script must be run on macOS."
fi

if ! command -v brew &>/dev/null; then
    error "Homebrew is not installed. Run 01-admin-setup.sh first."
fi

echo ""
echo "=========================================="
echo "  OpenClaw Mac Mini — Dev Environment"
echo "=========================================="
echo ""

# --- GitHub CLI ---------------------------------------------------------------

info "Checking for GitHub CLI..."
if command -v gh &>/dev/null; then
    info "GitHub CLI is already installed: $(gh --version | head -1)"
else
    info "Installing GitHub CLI..."
    brew install gh
    info "GitHub CLI installed: $(gh --version | head -1)"
fi

# --- Claude Code CLI ----------------------------------------------------------

# Ensure ~/.local/bin is on PATH (where Claude Code installs to)
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
if ! grep -q '.local/bin' "$HOME/.zprofile" 2>/dev/null; then
    echo >> "$HOME/.zprofile"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
    info "Added ~/.local/bin to PATH in ~/.zprofile"
fi

info "Checking for Claude Code..."
if command -v claude &>/dev/null; then
    info "Claude Code is already installed: $(claude --version 2>/dev/null || echo 'installed')"
else
    info "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    info "Claude Code installed."
fi

# --- nvm + Node.js (needed for gws CLI) ----------------------------------------

export NVM_DIR="$HOME/.nvm"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    info "nvm is already installed."
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
else
    info "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    info "nvm installed."
fi

if nvm ls 22 &>/dev/null; then
    info "Node.js 22 is already installed."
    nvm use 22
else
    info "Installing Node.js 22 via nvm..."
    nvm install 22
    nvm alias default 22
    info "Node.js 22 installed."
fi

info "Node.js version: $(node --version)"

# --- Google Workspace CLI ------------------------------------------------------

info "Checking for Google Workspace CLI (gws)..."
if command -v gws &>/dev/null; then
    info "gws CLI is already installed: $(gws --version 2>/dev/null || echo 'installed')"
else
    info "Installing Google Workspace CLI via npm..."
    npm install -g @googleworkspace/cli
    info "gws CLI installed: $(gws --version 2>/dev/null || echo 'installed')"
fi

# --- Google Cloud SDK (gcloud) ------------------------------------------------

info "Checking for Google Cloud SDK (gcloud)..."
if command -v gcloud &>/dev/null; then
    info "gcloud CLI is already installed: $(gcloud --version 2>/dev/null | head -1)"
else
    info "Installing Google Cloud SDK via Homebrew..."
    brew install --cask google-cloud-sdk

    # Add gcloud to PATH for this session
    GCLOUD_INC="$(brew --prefix)/share/google-cloud-sdk/path.zsh.inc"
    if [[ -f "$GCLOUD_INC" ]]; then
        # shellcheck source=/dev/null
        source "$GCLOUD_INC"
    fi

    # Add to shell profile for future sessions
    if ! grep -q 'google-cloud-sdk/path.zsh.inc' "$HOME/.zprofile" 2>/dev/null; then
        echo >> "$HOME/.zprofile"
        echo '# Google Cloud SDK' >> "$HOME/.zprofile"
        echo 'source "$(brew --prefix)/share/google-cloud-sdk/path.zsh.inc"' >> "$HOME/.zprofile"
        echo 'source "$(brew --prefix)/share/google-cloud-sdk/completion.zsh.inc"' >> "$HOME/.zprofile"
        info "Added gcloud to PATH in ~/.zprofile"
    fi

    if command -v gcloud &>/dev/null; then
        info "gcloud CLI installed: $(gcloud --version 2>/dev/null | head -1)"
    else
        warn "gcloud installed but not yet on PATH. Restart your shell or run: source $(brew --prefix)/share/google-cloud-sdk/path.zsh.inc"
    fi
fi

# --- Google Workspace Auth (manual) -------------------------------------------

echo ""
info "To set up Google Workspace credentials for the OpenClaw bot, run these"
info "commands manually after the script completes:"
echo ""
echo "  gws auth setup                  # create a Google Cloud project + enable APIs"
echo "  gws auth login -s gmail,calendar  # log in (opens browser)"
echo "  gws auth export --unmasked > /tmp/gws-credentials.json"
echo ""
info "Then provide /tmp/gws-credentials.json when running 02-openclaw-setup.sh."
info "See the README for full instructions."

# --- GitHub Auth --------------------------------------------------------------

echo ""
if gh auth status &>/dev/null 2>&1; then
    info "GitHub CLI is already authenticated."
else
    warn "GitHub CLI is not authenticated."
    read -rp "Run 'gh auth login' now? (Y/n): " do_auth
    if [[ ! "$do_auth" =~ ^[Nn]$ ]]; then
        gh auth login
    else
        info "Skipped. Run 'gh auth login' later to authenticate."
    fi
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "=========================================="
echo "  Dev Environment Setup Complete"
echo "=========================================="
echo ""
info "Installed:"
echo "  gh           $(gh --version 2>/dev/null | head -1 || echo 'not found')"
echo "  claude-code  $(claude --version 2>/dev/null || echo 'not found')"
echo "  gcloud       $(gcloud --version 2>/dev/null | head -1 || echo 'not found')"
echo "  gws          $(gws --version 2>/dev/null || echo 'not found')"
echo ""
