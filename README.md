# cc-switch — Claude Code Model + Menu Manager

**macOS Edition** (bash/zsh)

One-stop solution for Claude Code CLI on macOS:

- **Model Switching**: Switch AI models + OAuth bypass (no login)
- **Dynamic Menu**: Model list auto-updates from your available models
- **CPA Sync**: Fetch, diff, add/remove models from your CPA proxy
- **Skill Menu Management**: Audit, hide/show, preset profiles
- **Secret Management**: `.env` based API key config
- **Terminal Enhancements**: Optional Oh My Posh, zoxide

Originally [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch) (Windows/PowerShell) — ported to macOS (bash/zsh).

## Quick Start

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash

# Or manual
bash install.sh
source ~/.zshrc
```

## Usage

```bash
# Show menu
cc

# Switch model + launch Claude Code
cc claude-sonnet-4.6
cc gpt-5.5
cc deepseek-v4-flash

# Quick shortcuts
cc-pro         # claude-opus-4-7
cc-fast        # deepseek-v4-flash
cc-default     # gpt-5.5

# Status
cc-status

# CPA model sync
cc-sync              # fetch and diff
cc-sync --list       # show full CPA model list only
cc-sync --force      # auto-add new models
cc-sync --remove     # remove obsolete models

# Skill menu management
cc-audit             # full visibility report
cc-hide docx         # hide a skill
cc-show docx         # restore
cc-profile minimal   # switch preset (default|minimal|dev)
cc-commands          # list/manage custom commands

# Theme switching (Oh My Posh)
cc-theme             # list themes
cc-theme catppuccin  # switch theme (live preview)
```

## Configure Secrets

Edit `~/.claude/cc-switch.env`:

```
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

## Project Structure

```
cc-switch/
├── cc-switch.sh          # Core: model switch + menu + theme (bash/zsh)
├── install.sh            # macOS installer
├── .env.example          # Secret template
├── .gitignore
├── LICENSE
├── README.md
├── switch.md             # Slash command reference
└── skills/cc-menu/       # CPA Cleaner scripts (Python, cross-platform)
    ├── SKILL.md
    ├── bin/
    │   ├── cc-menu.sh
    │   ├── proxy_cpa_cleaner.py
    │   └── test_and_register_models.py
    └── docs/
        └── CPA-MultiModel-Cleaner-Guide.md
```

## Related

- Original: [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch)
- Hermes Agent: [hermes-agent.nousresearch.com](https://hermes-agent.nousresearch.com/docs)

## License

MIT
