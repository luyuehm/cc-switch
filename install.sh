#!/bin/bash
# install.sh — cc-switch macOS installer
# Sets up: model switching, OAuth bypass, skill menu management, slash commands
# Run: bash install.sh
# Web: curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash

set -e

echo ""
echo " ==============================================="
echo "   cc-switch — Claude Code Model + Menu Manager"
echo "   macOS Edition"
echo " ==============================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# [1/5] Copy cc-switch.sh to ~/.claude/
echo "[1/5] Installing core script to ~/.claude/cc-switch.sh..."
mkdir -p "$HOME/.claude"
if [[ -f "$SCRIPT_DIR/cc-switch.sh" ]]; then
  cp "$SCRIPT_DIR/cc-switch.sh" "$HOME/.claude/cc-switch.sh"
  chmod +x "$HOME/.claude/cc-switch.sh"
  echo "  [OK]  Core script installed"
else
  echo "  (!)   cc-switch.sh not found alongside installer" >&2
  exit 1
fi

# [2/5] Copy cc-menu Python scripts (optional advanced features)
echo ""
echo "[2/5] Installing cc-menu skill management (optional)..."
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

# [3/5] Set up .env for secrets
echo ""
echo "[3/5] Setting up cc-switch.env for secrets..."
ENV_TARGET="$HOME/.claude/cc-switch.env"
if [[ ! -f "$ENV_TARGET" ]]; then
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_TARGET"
    echo "  Created: $ENV_TARGET"
    echo "  [EDIT]   Edit this file to set your:"
    echo "      ANTHROPIC_API_KEY"
    echo "      ANTHROPIC_BASE_URL (or CPA_MODELS_URL)"
  else
    cat > "$ENV_TARGET" << 'EOF'
# cc-switch environment configuration
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-proxy.example.com
# CPA_MODELS_URL=https://your-proxy.example.com/v1/models
EOF
    echo "  Created: $ENV_TARGET (from template)"
  fi
else
  echo "  [INFO]   cc-switch.env already exists, skipping..."
fi

# [4/5] Update .zshrc
echo ""
echo "[4/5] Configuring shell profile..."
ZSHRC="$HOME/.zshrc"
CC_BLOCK='# === cc-switch — Claude Code Model + Menu Manager ===
# https://github.com/luyuehm/cc-switch

# Oh My Posh (prompt theme) — macOS
if command -v oh-my-posh &>/dev/null; then
  eval "$(oh-my-posh init zsh --config "$(oh-my-posh cache path 2>/dev/null)/themes/powerlevel10k_rainbow.omp.json" 2>/dev/null || oh-my-posh init zsh)"
fi

# zoxide (smart cd) — macOS
if command -v zoxide &>/dev/null; then
  eval "$(zoxide init zsh)"
fi

# cc-switch core
if [[ -f "$HOME/.claude/cc-switch.sh" ]]; then
  . "$HOME/.claude/cc-switch.sh"
else
  echo "[cc-switch] Not installed. Run: curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash"
fi
# <<< cc-switch'

if [[ -f "$ZSHRC" ]]; then
  if grep -q "cc-switch" "$ZSHRC"; then
    echo "  [INFO]   cc-switch already in .zshrc, skipping..."
  else
    echo "" >> "$ZSHRC"
    echo "$CC_BLOCK" >> "$ZSHRC"
    echo "  [OK]  Appended to: $ZSHRC"
  fi
else
  echo "$CC_BLOCK" > "$ZSHRC"
  echo "  [OK]  Created: $ZSHRC"
fi

# [5/5] Optional: install macOS terminal enhancements
echo ""
echo "[5/5] Optional: Install macOS terminal enhancements?"
echo "  (Oh My Posh theme, zoxide, python3 dependencies)"
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
    echo "  Note: Terminal-Icons is Windows-only."
    echo "  macOS equivalent: use 'ls -G' or 'eza' (brew install eza)"
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
echo "Next steps:"
echo "  1. Edit ~/.claude/cc-switch.env with your API key and CPA URL"
echo "  2. Reload profile: source ~/.zshrc"
echo "  3. Try: cc gpt-5.5    (switch model + launch)"
echo "          cc            (show menu)"
echo "          cc-audit      (audit skill visibility)"
echo "          cc-profile minimal   (hide docs/examples)"
echo ""

if [[ -z "${SKIP_RELOAD:-}" ]]; then
  echo "Reloading .zshrc..."
  source "$HOME/.claude/cc-switch.sh" 2>/dev/null || true
  echo ""
  echo "Tip: Run 'cc' to see the full menu"
fi
