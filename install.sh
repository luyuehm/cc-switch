#!/bin/bash
# install.sh — cc-switch macOS installer
# Sets up: model switching, health check, CPA auto-discovery, 
#           task scheduling (cc-run), skill menu management, slash commands
# Run: bash install.sh
# Web: curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash

set -e

echo ""
echo " ==============================================="
echo "   cc-switch — Claude Code Model + Menu Manager"
echo "   macOS Edition  v2.4.0"
echo " ==============================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# [1/6] Copy cc-switch.sh to ~/.claude/
echo "[1/6] Installing core script to ~/.claude/cc-switch.sh..."
mkdir -p "$HOME/.claude"
if [[ -f "$SCRIPT_DIR/cc-switch.sh" ]]; then
  cp "$SCRIPT_DIR/cc-switch.sh" "$HOME/.claude/cc-switch.sh"
  chmod +x "$HOME/.claude/cc-switch.sh"
  sed -i '' 's/\r$//' "$HOME/.claude/cc-switch.sh" 2>/dev/null || true
  echo "  [OK]  Core script installed"
else
  echo "  (!)   cc-switch.sh not found alongside installer" >&2
  exit 1
fi

# [2/6] Copy cc-menu Python scripts (optional advanced features)
echo ""
echo "[2/6] Installing cc-menu skill management (optional)..."
SKILLS_DIR="$HOME/.claude/skills/cc-menu"
if [[ -d "$SKILLS_DIR" ]]; then
  echo "  [INFO]   cc-menu skills already exist, skipping..."
else
  if [[ -d "$SCRIPT_DIR/skills/cc-menu" ]]; then
    mkdir -p "$SKILLS_DIR"
    cp -R "$SCRIPT_DIR/skills/cc-menu/." "$SKILLS_DIR"
    echo "  [OK]  cc-menu skills installed to $SKILLS_DIR"
  else
    echo "  (!)   cc-menu skills not found (optional, skipped)"
  fi
fi

# [3/6] Copy switch.md slash command
echo ""
echo "[3/6] Installing /switch slash command..."
COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"
if [[ -f "$SCRIPT_DIR/switch.md" ]]; then
  cp "$SCRIPT_DIR/switch.md" "$COMMANDS_DIR/switch.md"
  echo "  [OK]  /switch installed to $COMMANDS_DIR/switch.md"
else
  echo "  (!)   switch.md not found (optional, skipped)"
fi

# [4/6] Set up .env for secrets
echo ""
echo "[4/6] Setting up cc-switch.env for secrets..."
ENV_TARGET="$HOME/.claude/cc-switch.env"
if [[ ! -f "$ENV_TARGET" ]]; then
  cat > "$ENV_TARGET" << 'EOF'
# cc-switch environment configuration
# This file is a FALLBACK — shell env vars take priority.
#
# Recommended: use ~/.openclaw/.env as single source of truth:
#   CLAUDE_CODE_BASE_URL=https://your-cpa-proxy.com/
#   CPA_API_KEY=your-api-key-here
#
# Then add to ~/.zshrc:
#   __cc_url="$(grep '^CLAUDE_CODE_BASE_URL=' $HOME/.openclaw/.env | cut -d= -f2-)"
#   __cc_key="$(grep '^CPA_API_KEY=' $HOME/.openclaw/.env | cut -d= -f2-)"
#   export ANTHROPIC_BASE_URL="$__cc_url"
#   export ANTHROPIC_AUTH_TOKEN="$__cc_key"
#   unset __cc_url __cc_key
#
# If NOT using unified .env, uncomment and set:
# ANTHROPIC_API_KEY=your-api-key-here
# ANTHROPIC_BASE_URL=https://your-proxy.example.com
# CPA_MODELS_URL=https://your-proxy.example.com/v1/models
EOF
  echo "  Created: $ENV_TARGET"
  echo "  [EDIT]   Edit this file or use ~/.openclaw/.env for unified config"
else
  echo "  [INFO]   cc-switch.env already exists, skipping..."
fi

# [5/6] Detect existing Claude Code and ccx
echo ""
echo "[5/6] Checking environment..."
CLAUDE_BIN=""
for cb in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
  if [[ -x "$cb" ]]; then
    CLAUDE_BIN="$cb"
    break
  fi
done
if [[ -n "$CLAUDE_BIN" ]]; then
  echo "  [OK]  Claude Code found: $CLAUDE_BIN"
else
  echo "  [!]   Claude Code not found. Install with:"
  echo "           npm install -g @anthropic-ai/claude-code"
  echo "        Or: brew install claude-code"
fi

if command -v ccx &>/dev/null; then
  echo "  [OK]  ccx detected — cc-switch will integrate health checks"
fi

if [[ -f "$HOME/.openclaw/.env" ]]; then
  echo "  [OK]  ~/.openclaw/.env detected — cc-switch will use it as fallback"
fi

# [6/6] Update .zshrc
echo ""
echo "[6/6] Configuring shell profile..."
ZSHRC="$HOME/.zshrc"

HAS_CCX=false
HAS_CCSWITCH=false
[[ -f "$ZSHRC" ]] && grep -q "ccx" "$ZSHRC" 2>/dev/null && HAS_CCX=true
[[ -f "$ZSHRC" ]] && grep -q "cc-switch.sh" "$ZSHRC" 2>/dev/null && HAS_CCSWITCH=true

if [[ "$HAS_CCSWITCH" == "true" ]]; then
  echo "  [INFO]   cc-switch already in .zshrc, skipping..."
elif [[ "$HAS_CCX" == "true" ]]; then
  # ccx present — add cc-switch with integrated cc()
  echo "  [OK]  ccx detected — installing cc-switch alongside ccx"
  echo "" >> "$ZSHRC"
  echo '# >>> cc-switch — Claude Code Model Switcher (integrated with ccx)' >> "$ZSHRC"
  echo 'if [[ -f "$HOME/.claude/cc-switch.sh" ]]; then' >> "$ZSHRC"
  echo '  unalias cc 2>/dev/null || true  # avoid alias=ccx conflict' >> "$ZSHRC"
  echo '  . "$HOME/.claude/cc-switch.sh"' >> "$ZSHRC"
  echo 'fi' >> "$ZSHRC"
  echo '# <<< cc-switch' >> "$ZSHRC"
  echo "  Note: cc() is already defined by ccx. cc-switch helpers (cc-run, cc-config, cc-test) are available."
else
  # No ccx — install standalone
  echo '  [OK]  Installing standalone cc-switch'
  echo "" >> "$ZSHRC"
  echo '# >>> cc-switch — Claude Code Model Switcher' >> "$ZSHRC"
  echo 'if [[ -f "$HOME/.claude/cc-switch.sh" ]]; then' >> "$ZSHRC"
  echo '  unalias cc 2>/dev/null || true' >> "$ZSHRC"
  echo '  . "$HOME/.claude/cc-switch.sh"' >> "$ZSHRC"
  echo 'fi' >> "$ZSHRC"
  echo '# <<< cc-switch' >> "$ZSHRC"
fi

# Optional: install macOS terminal enhancements
echo ""
echo "Optional: Install macOS terminal enhancements?"
echo "  (Oh My Posh theme, zoxide)"
echo -n "  Install via Homebrew? [y/N] "
read -r install_tools
if [[ "$install_tools" == "y" || "$install_tools" == "Y" ]]; then
  if ! command -v brew &>/dev/null; then
    echo "  Homebrew not found. Install from https://brew.sh first."
    echo "  [SKIP]   Skipping brew installs"
  else
    echo "  Installing Oh My Posh..."
    brew install oh-my-posh 2>/dev/null || brew upgrade oh-my-posh

    echo "  Installing zoxide..."
    brew install zoxide 2>/dev/null || brew upgrade zoxide

    echo "  [OK]  Tools installed"
  fi
else
  echo "  [SKIP]   Tools skipped"
  echo "  Install later: brew install oh-my-posh zoxide"
fi

echo ""
echo ""
echo " ==============================================="
echo "   Installation Complete!"
echo " ==============================================="
echo ""
echo "=== What was installed ==="
echo "  Core:       ~/.claude/cc-switch.sh"
echo "  Slash cmd:  ~/.claude/commands/switch.md"
echo "  Skills:     ~/.claude/skills/cc-menu/"
echo "  Config:     ~/.claude/cc-switch.env"
echo "  Shell:      .zshrc updated"
echo ""
echo "=== Quick Start ==="
echo "  1. Configure API access:"
echo "     Recommended: edit ~/.openclaw/.env"
echo "       CLAUDE_CODE_BASE_URL=https://your-cpa-proxy.com/"
echo "       CPA_API_KEY=your-key"
echo "     Or: edit ~/.claude/cc-switch.env"
echo ""
echo "  2. Reload: source ~/.zshrc"
echo ""
echo "  3. Try:"
echo "     cc              Auto-discover CPA models + assign tasks"
echo "     cc-run code     Launch with code model"
echo "     cc-run reason   Launch with reasoning model"
echo "     cc-sync         Sync models from CPA"
echo "     cc-config       View task assignments"
echo "     cc-test         Test all models"
echo "     cc-status       Full inventory"
echo ""
