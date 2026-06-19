# cc-switch — Claude Code Model + Menu Manager

**Cross-platform** — macOS (bash/zsh) + Windows (PowerShell)

One-stop solution for Claude Code CLI:

- **Model Switching**: Switch AI models + OAuth bypass (no login)
- **Dynamic Menu**: Model list auto-updates from your available models
- **CPA Sync**: Fetch, diff, add/remove models from your CPA proxy
- **Skill Menu Management**: Audit, hide/show, preset profiles
- **Secret Management**: `.env` based API key config
- **Terminal Enhancements**: Optional Oh My Posh, zoxide (macOS)

Originally [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch) (Windows/PowerShell).

---

## 🍎 macOS (bash/zsh)

### Quick Start

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash

# Or manual
bash install.sh
source ~/.zshrc
```

### Shell Commands

```bash
cc                  # Show model selection menu
cc <model>          # Switch model + launch Claude Code
cc-pro              # Switch to claude-opus-4-7
cc-fast             # Switch to deepseek-v4-flash
cc-default          # Switch to gpt-5.5
cc-status           # Show current model + full list
cc-sync             # Fetch CPA models, diff with local
cc-sync --list      # Show full CPA model list only
cc-sync --force     # Auto-add new CPA models
cc-sync --remove    # Remove obsolete models
cc-audit            # Full skill visibility report
cc-hide <skill>     # Hide a skill from Claude Code
cc-show <skill>     # Restore a hidden skill
cc-profile <preset> # Switch visibility preset (default|minimal|dev)
cc-commands list    # List custom slash commands
cc-commands create  # Create a new slash command
cc-commands remove  # Remove a slash command
cc-theme            # List Oh My Posh themes
cc-theme <name>     # Switch theme (live preview)
```

### Configure Secrets

Edit `~/.claude/cc-switch.env`:

```
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

`ANTHROPIC_API_KEY` is stored in the env file. At shell startup the key is **not** loaded (`CC_SWITCH_SKIP_ENV=1` in `.zshrc`). When `cc <model>` runs, it exports the key as `ANTHROPIC_AUTH_TOKEN` (sent as `Authorization: Bearer`) to avoid auth conflicts with `claude.ai` OAuth sessions.

---

## 🪟 Windows (PowerShell)

> Based on the original [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch).

### Quick Start

```powershell
# One-line install (run in PowerShell as Administrator)
iwr -Uri https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex

# Or manual
.\install.ps1
```

### Shell Commands (PowerShell)

```powershell
cc                  # Show model selection menu
cc <model>          # Switch model, prompts to launch Claude Code
cc-pro              # Switch to claude-opus-4-7
cc-fast             # Switch to deepseek-v4-flash
cc-default          # Switch to gpt-5.5
cc-status           # Show current model + full list
cc-sync             # Fetch CPA models, diff with local
cc-sync --list      # Show full CPA model list only
cc-sync --force     # Auto-add new CPA models
cc-sync --remove    # Remove obsolete models
cc-audit            # Full skill visibility report
cc-hide <skill>     # Hide a skill from Claude Code
cc-show <skill>     # Restore a hidden skill
cc-profile <preset> # Switch visibility preset (default|minimal|dev)
cc-commands list    # List custom slash commands
cc-commands create  # Create a new slash command
cc-commands remove  # Remove a slash command
```

### Configure Secrets (Windows)

Edit `~\\.claude\\cc-switch.env` (or `$env:USERPROFILE\.claude\cc-switch.env`):

```
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### Path Reference (Windows)

| Item | Path |
|------|------|
| Config | `C:\Users\<you>\.claude\settings.json` |
| Secrets | `C:\Users\<you>\.claude\cc-switch.env` |
| Script | `C:\Users\<you>\.claude\cc-switch.ps1` |
| Cache | `C:\Users\<you>\.claude\.cpa-cache.json` |
| Profile | `$PROFILE` (PowerShell profile) |

---

## /switch Slash Command (both platforms)

The `/switch` slash command works inside Claude Code on both macOS and Windows. It is installed as a skill at `~/.claude/commands/switch.md`.

| Command | Action |
|---------|--------|
| `/switch` | List all models with CPA detection |
| `/switch gpt-5.5` | Switch to GPT-5.5 |
| `/switch --offline` | List local models only (no network) |
| `/switch --status` | CPA detection summary only |
| `/switch --add <name>` | Add model to availableModels |
| `/switch --remove <name>` | Remove model from availableModels |

## 🔧 MacOS-Specific Fixes

### Binary Detection
`cc-switch` locates Claude Code by checking known paths (`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`) and verifying the binary with `--version | grep "Claude Code"`. Falls back to `npx @anthropic-ai/claude-code` if not found.

### Settings Auto-Creation
`~/.claude/settings.json` is created automatically with a valid JSON structure if missing or corrupted. No manual setup needed.

### Auto-Add Models
`cc <model>` automatically adds the model to `availableModels` if it's not already in the list. No need to run `cc-sync` first.

### JSON Validation
`settings.json` is validated as JSON on every read. If corrupt (empty, truncated, malformed), it's reset to `{"availableModels":[],"env":{}}`.

## ⚠ claude.ai Auth Conflict

**Problem**: When both Claude Code CLI OAuth session and `ANTHROPIC_API_KEY` env var are present, Claude Code shows:

> ⚠ Both claude.ai and ANTHROPIC_API_KEY set · auth may not work as expected

**Solution**: `cc-switch` handles this automatically:

- At shell startup, `CC_SWITCH_SKIP_ENV=1` (set in `.zshrc`) prevents auto-loading the API key — `claude` run directly uses claude.ai auth.
- When `cc <model>` runs, it force-loads the env file and exports the key as `ANTHROPIC_AUTH_TOKEN` instead of `ANTHROPIC_API_KEY`, sending `Authorization: Bearer` to your proxy, with no conflict warning.

| Scenario | Auth sent | Result |
|----------|-----------|--------|
| Shell startup | None (guard active) | No conflict |
| `cc <model>` | `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer` | No warning |
| `claude` directly | claude.ai OAuth only | Normal behavior |

## Project Structure

```
cc-switch/
├── cc-switch.sh          # Core functions: model switch + menu + theme (bash/zsh)
├── cc-switch.ps1         # Core functions: model switch + menu + theme (PowerShell)
├── install.sh            # macOS installer (bash)
├── install.ps1           # Windows installer (PowerShell)
├── .env.example          # Secret template
├── .gitignore
├── LICENSE
├── README.md
├── switch.md             # Slash command reference (cross-platform)
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
