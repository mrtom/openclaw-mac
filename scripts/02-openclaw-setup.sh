#!/bin/bash
# =============================================================================
# 02-openclaw-setup.sh — Run as the 'openclaw' standard user
#
# This script:
#   1. Installs nvm + Node.js 22
#   2. Installs OpenClaw via npm
#   3. Sets up Obsidian vault with plugins
#   4. Prompts for secrets and writes them to a secured file
#   5. Prompts for bot name + owner name and generates personality prompt
#   6. Writes the OpenClaw config (openclaw.json)
#   7. Creates a gateway wrapper script (start.sh)
#   8. Generates the LaunchDaemon plist (to be installed by admin)
#   9. Locks down file permissions
#  10. Runs security audit
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}--- $* ---${NC}\n"; }

# --- Pre-flight checks -------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
    error "This script must be run on macOS."
fi

if dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -qw "$(whoami)"; then
    warn "You are running this as an admin user."
    warn "For security, this should be run as the 'openclaw' standard user."
    read -rp "Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

OPENCLAW_HOME="$HOME/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_VERSION="2026.2.15"

echo ""
echo "=========================================="
echo "  OpenClaw Mac Mini — OpenClaw Setup"
echo "=========================================="
echo ""

# --- 1. Install nvm ----------------------------------------------------------

step "Installing nvm"

export NVM_DIR="$HOME/.nvm"

if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    info "nvm is already installed."
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
else
    info "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

    # Source nvm for this session
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    info "nvm installed."
fi

# --- 2. Install Node.js 22 ---------------------------------------------------

step "Installing Node.js 22"

if nvm ls 22 &>/dev/null; then
    info "Node.js 22 is already installed."
    nvm use 22
else
    info "Installing Node.js 22 via nvm..."
    nvm install 22
    nvm alias default 22
    info "Node.js 22 installed."
fi

node_version=$(node --version)
info "Node.js version: $node_version"

# --- 3. Install OpenClaw -----------------------------------------------------

step "Installing OpenClaw"

if command -v openclaw &>/dev/null; then
    info "OpenClaw is already installed."
else
    info "Installing OpenClaw via npm..."
    npm install -g openclaw@latest
    info "OpenClaw installed."
fi

# Version check
openclaw_version=$(openclaw --version) || error "Failed to get OpenClaw version."
info "OpenClaw version: $openclaw_version"

# Compare versions (simple numeric comparison)
version_num=$(echo "$openclaw_version" | sed 's/[^0-9.]//g' | head -1)
if [[ -z "$version_num" ]]; then
    error "Could not parse OpenClaw version from: $openclaw_version"
fi
if [[ "$(printf '%s\n' "$MIN_VERSION" "$version_num" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
    error "OpenClaw version $openclaw_version is below minimum $MIN_VERSION (CVE-2026-25253, GHSA-chf7-jq6g-qrwv). Please upgrade."
fi
info "Version $openclaw_version meets minimum requirement ($MIN_VERSION)."

# --- 3b. Install Google Workspace CLI -----------------------------------------

step "Installing Google Workspace CLI (gws)"

if command -v gws &>/dev/null; then
    info "gws CLI is already installed."
else
    info "Installing gws CLI via npm..."
    npm install -g @googleworkspace/cli
    info "gws CLI installed."
fi

gws_version=$(gws --version 2>/dev/null) || warn "Could not determine gws version."
if [[ -n "${gws_version:-}" ]]; then
    info "gws CLI version: $gws_version"
fi

# --- 4. Create OpenClaw directory ---------------------------------------------

step "Setting up OpenClaw directory"

mkdir -p "$OPENCLAW_HOME"
mkdir -p "$OPENCLAW_HOME/credentials"
mkdir -p "$OPENCLAW_HOME/agents"
mkdir -p "$OPENCLAW_HOME/workspace"

# --- 4b. Set up Obsidian vault ------------------------------------------------

step "Setting up Obsidian vault"

VAULT_DIR="$OPENCLAW_HOME/workspace/obsidian-vault"

if [[ ! -d "$VAULT_DIR" ]]; then
    # First install — copy entire template vault from repo
    info "Creating Obsidian vault from template..."
    cp -r "$SCRIPT_DIR/../obsidian-vault" "$VAULT_DIR"
    info "Vault created at $VAULT_DIR"
else
    # Re-run — ensure directories exist, never touch user content
    info "Obsidian vault already exists. Ensuring directories..."
    mkdir -p "$VAULT_DIR/Daily Notes"
    mkdir -p "$VAULT_DIR/Templates"
    mkdir -p "$VAULT_DIR/People"
    # Only copy new config files (don't overwrite existing)
    cp -rn "$SCRIPT_DIR/../obsidian-vault/.obsidian" "$VAULT_DIR/.obsidian" 2>/dev/null || true
    info "Vault directories verified."
fi

# Download Obsidian Tasks plugin from GitHub releases
download_plugin() {
    local repo="$1"
    local plugin_id="$2"
    local plugin_dir="$VAULT_DIR/.obsidian/plugins/$plugin_id"

    if [[ -f "$plugin_dir/main.js" && -f "$plugin_dir/manifest.json" ]]; then
        info "Plugin '$plugin_id' is already installed."
        return 0
    fi

    info "Installing plugin '$plugin_id' from $repo..."
    mkdir -p "$plugin_dir"

    # Get the latest release tag
    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [[ -z "$latest_tag" ]]; then
        warn "Could not determine latest release for $repo. Skipping plugin."
        return 1
    fi

    local base_url="https://github.com/$repo/releases/download/$latest_tag"

    curl -fsSL "$base_url/main.js" -o "$plugin_dir/main.js" \
        || { warn "Failed to download main.js for $plugin_id"; return 1; }

    curl -fsSL "$base_url/manifest.json" -o "$plugin_dir/manifest.json" \
        || { warn "Failed to download manifest.json for $plugin_id"; return 1; }

    # styles.css is optional
    curl -fsSL "$base_url/styles.css" -o "$plugin_dir/styles.css" 2>/dev/null || true

    info "Plugin '$plugin_id' installed (version: $latest_tag)."
}

download_plugin "obsidian-tasks-group/obsidian-tasks" "obsidian-tasks-plugin"

# Install OpenClaw Obsidian skill from ClawHub
info "Checking for steipete/obsidian ClawHub skill..."
SKILLS_DIR="$OPENCLAW_HOME/workspace/skills"
if [[ -d "$SKILLS_DIR/steipete/obsidian" ]]; then
    info "ClawHub skill steipete/obsidian is already installed."
else
    info "Installing steipete/obsidian skill from ClawHub..."
    cd "$OPENCLAW_HOME/workspace"
    clawhub install steipete/obsidian || warn "Failed to install steipete/obsidian skill. You can install it manually later with: clawhub install steipete/obsidian"
    cd - > /dev/null
fi

# Install Google Workspace ClawHub skills
GWS_SKILLS=(
    "googleworkspace-bot/gws-shared"
    "googleworkspace-bot/gws-gmail"
    "googleworkspace-bot/gws-calendar"
)

for skill in "${GWS_SKILLS[@]}"; do
    skill_dir="$SKILLS_DIR/$skill"
    if [[ -d "$skill_dir" ]]; then
        info "ClawHub skill $skill is already installed."
    else
        info "Installing $skill skill from ClawHub..."
        cd "$OPENCLAW_HOME/workspace"
        clawhub install "$skill" || warn "Failed to install $skill skill. You can install it manually later with: clawhub install $skill"
        cd - > /dev/null
    fi
done

# --- 5. Collect and store secrets ---------------------------------------------

step "Configuring secrets"

SECRETS_FILE="$OPENCLAW_HOME/secrets.env"

# Helper: mask a secret for display (first 4 chars + "…redacted", or "(not set)")
mask_secret() {
    local val="$1"
    if [[ -z "$val" ]]; then
        echo "(not set)"
    else
        echo "${val:0:4}…redacted"
    fi
}

if [[ -f "$SECRETS_FILE" ]]; then
    # Load existing secrets so we can selectively update
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"

    info "Secrets file found. You can update individual secrets or keep existing values."
    echo ""

    # --- Anthropic API key ---
    echo "  Anthropic API key:  $(mask_secret "${ANTHROPIC_API_KEY:-}")"
    read -rp "  Update? (y/N): " update_anthropic
    if [[ "$update_anthropic" =~ ^[Yy]$ ]]; then
        echo "  Enter your Anthropic API key (starts with sk-ant-):"
        read -rsp "  > " new_val
        echo ""
        if [[ -n "$new_val" ]]; then
            ANTHROPIC_API_KEY="$new_val"
        else
            warn "  Empty value — keeping existing key."
        fi
    fi

    # --- Telegram bot token ---
    echo "  Telegram bot token: $(mask_secret "${TELEGRAM_BOT_TOKEN:-}")"
    read -rp "  Update? (y/N): " update_telegram
    if [[ "$update_telegram" =~ ^[Yy]$ ]]; then
        echo "  Enter your Telegram bot token (from @BotFather):"
        read -rsp "  > " new_val
        echo ""
        if [[ -n "$new_val" ]]; then
            TELEGRAM_BOT_TOKEN="$new_val"
        else
            warn "  Empty value — keeping existing token."
        fi
    fi

    # --- Telegram chat ID ---
    echo "  Telegram chat ID:   ${TELEGRAM_CHAT_ID:-(not set)}"
    read -rp "  Update? (y/N): " update_chat_id
    if [[ "$update_chat_id" =~ ^[Yy]$ ]]; then
        echo "  Enter your Telegram chat ID (get it from @userinfobot on Telegram):"
        read -rp "  > " new_val
        if [[ -n "$new_val" ]]; then
            TELEGRAM_CHAT_ID="$new_val"
        else
            warn "  Empty value — keeping existing chat ID."
        fi
    fi

    # --- Gemini API key ---
    echo "  Gemini API key:     $(mask_secret "${GEMINI_API_KEY:-}")"
    read -rp "  Update? (y/N): " update_gemini
    if [[ "$update_gemini" =~ ^[Yy]$ ]]; then
        echo "  Enter your Gemini API key (starts with AIza, or leave blank to skip web search):"
        read -rsp "  > " new_val
        echo ""
        GEMINI_API_KEY="$new_val"
    fi

    # --- Gateway token ---
    echo "  Gateway token:      $(mask_secret "${OPENCLAW_GATEWAY_TOKEN:-}")"
    read -rp "  Regenerate? (y/N): " regen_gateway
    if [[ "$regen_gateway" =~ ^[Yy]$ ]]; then
        OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
        info "  Gateway token regenerated."
    fi

else
    # Fresh install — prompt for all secrets
    echo ""
    echo "Enter your Anthropic API key (starts with sk-ant-):"
    read -rsp "> " ANTHROPIC_API_KEY
    echo ""

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        error "Anthropic API key cannot be empty."
    fi

    echo "Enter your Telegram bot token (from @BotFather):"
    read -rsp "> " TELEGRAM_BOT_TOKEN
    echo ""

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
        error "Telegram bot token cannot be empty."
    fi

    echo "Enter your Telegram chat ID (get it from @userinfobot on Telegram):"
    read -rp "> " TELEGRAM_CHAT_ID

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        error "Telegram chat ID cannot be empty."
    fi

    echo "Enter your Gemini API key (starts with AIza, or leave blank to skip web search):"
    read -rsp "> " GEMINI_API_KEY
    echo ""

    if [[ -n "$GEMINI_API_KEY" ]]; then
        info "Gemini API key provided — web search will be enabled."
    else
        warn "No Gemini API key provided — web search will not be available."
    fi

    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
    info "Generated random gateway auth token."
fi

# Write secrets file (always rewritten to pick up any changes)
cat > "$SECRETS_FILE" <<SECRETS_EOF
# OpenClaw secrets — generated by 02-openclaw-setup.sh
# This file is sourced by start.sh before launching the gateway.
# Permissions should be 600 (owner read/write only).

export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
export OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"
export TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
export GEMINI_API_KEY="${GEMINI_API_KEY:-}"
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$OPENCLAW_HOME/credentials/gws-credentials.json"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$OPENCLAW_HOME/credentials/gws-config"
SECRETS_EOF

chmod 600 "$SECRETS_FILE"
info "Secrets written to $SECRETS_FILE (mode 600)."

# Write Telegram bot token to its own file (tokenFile approach avoids env var leaks)
TELEGRAM_TOKEN_FILE="$OPENCLAW_HOME/credentials/telegram-token"
echo -n "$TELEGRAM_BOT_TOKEN" > "$TELEGRAM_TOKEN_FILE"
chmod 600 "$TELEGRAM_TOKEN_FILE"
info "Telegram token written to $TELEGRAM_TOKEN_FILE (mode 600)."

# --- 5b. Google Workspace credentials -----------------------------------------

step "Configuring Google Workspace credentials"

GWS_CREDS_FILE="$OPENCLAW_HOME/credentials/gws-credentials.json"
GWS_CONFIG_DIR="$OPENCLAW_HOME/credentials/gws-config"

mkdir -p "$GWS_CONFIG_DIR"

if [[ -f "$GWS_CREDS_FILE" ]]; then
    info "Google Workspace credentials file already exists at $GWS_CREDS_FILE"
    read -rp "  Replace? (y/N): " replace_gws
    if [[ "$replace_gws" =~ ^[Yy]$ ]]; then
        echo "  Provide the path to a gws credentials JSON file."
        echo "  (Generate one on the admin account: gws auth export --unmasked > credentials.json)"
        read -rp "  Path to credentials.json: " gws_creds_source
        if [[ -n "$gws_creds_source" && -f "$gws_creds_source" ]]; then
            cp "$gws_creds_source" "$GWS_CREDS_FILE"
            chmod 600 "$GWS_CREDS_FILE"
            info "Google Workspace credentials updated."
        else
            warn "File not found: ${gws_creds_source:-<empty>} — keeping existing credentials."
        fi
    else
        info "Keeping existing credentials."
    fi
else
    echo ""
    echo "  Google Workspace (Gmail, Calendar) requires OAuth credentials."
    echo "  From the admin account (after running 01a-dev-setup.sh), run:"
    echo "    gws auth setup                    # one-time project setup"
    echo "    gws auth login -s gmail,calendar  # log in (opens browser)"
    echo "    gws auth export --unmasked > /tmp/gws-credentials.json"
    echo ""
    read -rp "  Path to credentials.json (or leave blank to skip): " gws_creds_source

    if [[ -n "$gws_creds_source" && -f "$gws_creds_source" ]]; then
        cp "$gws_creds_source" "$GWS_CREDS_FILE"
        chmod 600 "$GWS_CREDS_FILE"
        info "Google Workspace credentials stored at $GWS_CREDS_FILE (mode 600)."
    elif [[ -n "$gws_creds_source" ]]; then
        warn "File not found: $gws_creds_source"
        warn "Skipping Google Workspace credentials. Re-run this script later to add them."
    else
        warn "Skipping Google Workspace credentials. Gmail and Calendar will not be available."
        warn "Re-run this script later with the credentials file to enable them."
    fi
fi

# --- 6. Collect identity (bot name + owner name) -----------------------------

step "Configuring identity"

IDENTITY_FILE="$OPENCLAW_HOME/identity.env"

if [[ -f "$IDENTITY_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$IDENTITY_FILE"

    info "Identity file found."
    echo "  Bot name:    ${BOT_NAME:-(not set)}"
    echo "  Owner name:  ${OWNER_NAME:-(not set)}"
    read -rp "  Update? (y/N): " update_identity
    if [[ "$update_identity" =~ ^[Yy]$ ]]; then
        read -rp "  What should the bot be called? " BOT_NAME
        [[ -z "$BOT_NAME" ]] && error "Bot name cannot be empty."
        read -rp "  What's your name? " OWNER_NAME
        [[ -z "$OWNER_NAME" ]] && error "Owner name cannot be empty."
    fi
else
    echo "Choose a name for your bot and tell it who you are."
    echo ""
    read -rp "What should the bot be called? " BOT_NAME
    [[ -z "$BOT_NAME" ]] && error "Bot name cannot be empty."
    read -rp "What's your name? " OWNER_NAME
    [[ -z "$OWNER_NAME" ]] && error "Owner name cannot be empty."
fi

cat > "$IDENTITY_FILE" <<IDENTITY_EOF
# OpenClaw identity — generated by 02-openclaw-setup.sh
export BOT_NAME="$BOT_NAME"
export OWNER_NAME="$OWNER_NAME"
IDENTITY_EOF

chmod 600 "$IDENTITY_FILE"
info "Identity written to $IDENTITY_FILE"

# Generate personality prompt from template
PERSONALITY_TEMPLATE="$SCRIPT_DIR/personality.txt.template"
PERSONALITY_FILE="$OPENCLAW_HOME/personality.txt"

if [[ ! -f "$PERSONALITY_TEMPLATE" ]]; then
    error "Personality template not found at $PERSONALITY_TEMPLATE"
fi

sed -e "s/{{BOT_NAME}}/$BOT_NAME/g" -e "s/{{OWNER_NAME}}/$OWNER_NAME/g" \
    "$PERSONALITY_TEMPLATE" > "$PERSONALITY_FILE"
chmod 600 "$PERSONALITY_FILE"
info "Personality prompt generated at $PERSONALITY_FILE"

# --- 7. Write OpenClaw config -------------------------------------------------

step "Writing OpenClaw configuration"

CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"

# Read the gateway token (either from just-created secrets or existing)
if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
fi

cat > "$CONFIG_FILE" <<CONFIG_EOF
{
  "auth": {
    "profiles": {
      "anthropic:default": {
        "provider": "anthropic",
        "mode": "api_key"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-6"
      },
      "models": {
        "anthropic/claude-sonnet-4-6": {},
        "anthropic/claude-opus-4-6": {}
      },
      "workspace": "$HOME/.openclaw/workspace",
      "compaction": {
        "mode": "safeguard"
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      },
      "heartbeat": {
        "every": "30m",
        "target": "telegram",
        "to": "$TELEGRAM_CHAT_ID"
      }
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true,
    "ownerDisplay": "raw"
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "tokenFile": "$OPENCLAW_HOME/credentials/telegram-token",
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "groups": {
        "*": { "requireMention": true }
      },
      "configWrites": false,
      "streaming": "off"
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "\${OPENCLAW_GATEWAY_TOKEN}"
    },
    "trustedProxies": ["127.0.0.1"],
    "tailscale": {
      "mode": "serve",
      "resetOnExit": true
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "web": {
      "search": {
        "enabled": true,
        "provider": "gemini",
        "maxResults": 5,
        "timeoutSeconds": 30,
        "cacheTtlMinutes": 15,
        "gemini": {
          "model": "gemini-2.5-flash"
        }
      }
    },
    "exec": {
      "ask": "always"
    },
    "elevated": {
      "enabled": false
    }
  },
  "skills": {
    "entries": {
      "steipete/obsidian": {
        "enabled": true,
        "config": {
          "vaultPath": "$HOME/.openclaw/workspace/obsidian-vault"
        }
      },
      "googleworkspace-bot/gws-shared": {
        "enabled": true
      },
      "googleworkspace-bot/gws-gmail": {
        "enabled": true
      },
      "googleworkspace-bot/gws-calendar": {
        "enabled": true
      }
    }
  },
  "logging": {
    "redactSensitive": "tools"
  },
  "discovery": {
    "mdns": {
      "mode": "minimal"
    }
  }
}
CONFIG_EOF

chmod 600 "$CONFIG_FILE"
info "Config written to $CONFIG_FILE"

# --- 8. Write the gateway wrapper script --------------------------------------

step "Creating gateway wrapper script"

WRAPPER_SCRIPT="$OPENCLAW_HOME/start.sh"
OPENCLAW_USER_HOME="$HOME"

cat > "$WRAPPER_SCRIPT" <<WRAPPER_EOF
#!/bin/bash
# OpenClaw gateway wrapper — sources nvm and secrets, then starts the gateway.
# This script is called by the LaunchDaemon on boot.

set -euo pipefail

# Source nvm
export NVM_DIR="$OPENCLAW_USER_HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"

# Source secrets (API keys, tokens)
SECRETS_FILE="$OPENCLAW_USER_HOME/.openclaw/secrets.env"
if [ -f "\$SECRETS_FILE" ]; then
    set -a
    source "\$SECRETS_FILE"
    set +a
else
    echo "ERROR: Secrets file not found at \$SECRETS_FILE" >&2
    exit 1
fi

# Start the gateway
exec openclaw gateway
WRAPPER_EOF

chmod 700 "$WRAPPER_SCRIPT"
info "Wrapper script written to $WRAPPER_SCRIPT"

# --- 9. Generate LaunchDaemon plist -------------------------------------------

step "Generating LaunchDaemon plist"

PLIST_FILE="$OPENCLAW_HOME/ai.openclaw.gateway.plist"
OPENCLAW_USERNAME="$(whoami)"

cat > "$PLIST_FILE" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.openclaw.gateway</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$OPENCLAW_USER_HOME/.openclaw/start.sh</string>
    </array>

    <key>UserName</key>
    <string>$OPENCLAW_USERNAME</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/openclaw/gateway.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/openclaw/gateway.err</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$OPENCLAW_USER_HOME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

info "LaunchDaemon plist generated at $PLIST_FILE"
info "This plist will be installed by the 01b-install-daemon.sh script (run as admin)."

# --- 10. File permissions lockdown --------------------------------------------

step "Locking down file permissions"

chmod 700 "$OPENCLAW_HOME"
chmod 600 "$OPENCLAW_HOME/openclaw.json"
chmod 600 "$SECRETS_FILE"
chmod 600 "$IDENTITY_FILE"
chmod 600 "$PERSONALITY_FILE"
chmod 700 "$WRAPPER_SCRIPT"
chmod 700 "$OPENCLAW_HOME/credentials"
chmod 700 "$OPENCLAW_HOME/agents"
chmod 700 "$OPENCLAW_HOME/workspace"

# Obsidian vault permissions
if [[ -d "$VAULT_DIR/.obsidian" ]]; then
    find "$VAULT_DIR/.obsidian" -type d -exec chmod 700 {} \;
    find "$VAULT_DIR/.obsidian" -type f -exec chmod 600 {} \;
fi

# Google Workspace credentials
if [[ -f "$OPENCLAW_HOME/credentials/gws-credentials.json" ]]; then
    chmod 600 "$OPENCLAW_HOME/credentials/gws-credentials.json"
fi
if [[ -d "$OPENCLAW_HOME/credentials/gws-config" ]]; then
    chmod 700 "$OPENCLAW_HOME/credentials/gws-config"
fi

info "Permissions set:"
echo "  drwx------  ~/.openclaw/"
echo "  -rw-------  ~/.openclaw/openclaw.json"
echo "  -rw-------  ~/.openclaw/secrets.env"
echo "  -rwx------  ~/.openclaw/start.sh"
echo "  drwx------  ~/.openclaw/workspace/"
echo "  drwx------  ~/.openclaw/workspace/obsidian-vault/.obsidian/"
echo "  -rw-------  ~/.openclaw/credentials/gws-credentials.json (if present)"
echo "  drwx------  ~/.openclaw/credentials/gws-config/"

# --- 11. Run security audit ---------------------------------------------------

step "Running security audit"

info "Running: openclaw security audit --deep"
openclaw security audit --deep || error "Security audit failed. Review output above and fix issues before continuing."

echo ""
info "Applying automatic fixes..."
openclaw security audit --fix || error "Security audit --fix failed. Review output above."

# --- Summary ------------------------------------------------------------------

echo ""
echo "=========================================="
echo "  OpenClaw Setup Complete"
echo "=========================================="
echo ""
info "Next steps:"
echo ""
echo "  1. Switch back to your admin account and run the daemon installer:"
echo "     exit"
echo "     bash $(dirname "$SCRIPT_DIR")/scripts/01b-install-daemon.sh"
echo ""
echo "  2. After the daemon is running, send a message to your Telegram bot."
echo "     You'll receive a pairing code. Approve it with:"
echo "     su - openclaw -c 'openclaw pairing approve telegram <CODE>'"
echo ""
echo "  3. Copy the personality prompt to send as your first message to $BOT_NAME:"
echo "     cat $OPENCLAW_HOME/personality.txt"
echo ""
echo "  4. Run the verification script:"
echo "     su - openclaw -c 'bash $(dirname "$SCRIPT_DIR")/scripts/03-verify.sh'"
echo ""
