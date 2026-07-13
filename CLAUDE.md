# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**cc-switch** is a PowerShell-based Claude Code CLI manager that provides:
- **Model switching** — switch AI models with OAuth bypass (no login prompt)
- **Dynamic model menu** — auto-categorizes models by provider from `settings.json`
- **CPA model sync** — fetch, diff, add/remove models from a CPA proxy endpoint
- **Skill menu management** — audit, hide/show skills, preset profiles (default/minimal/dev)
- **Secret management** — `.env`-based API key configuration
- **Terminal enhancements** — optional Oh My Posh, zoxide, Terminal-Icons
- **CPA Cleaner proxy** — local Python proxy that routes/translates between Anthropic ↔ OpenAI formats

## Project Structure

```
cc-switch/
├── cc-switch.ps1              # Core: model switch + menu + theme + skill management
├── install.ps1                # 5-step installer (copies scripts, sets up .env, profile, optional pwsh tools)
├── profile-backup.ps1         # Backup profile with pwsh utilities (network, git, system, aliases)
├── .env.example               # Secret template for API key + CPA URL
├── .gitignore                 # Excludes .env files
├── README.md                  # Full documentation
├── switch.md                  # Slash command reference for Claude Code
├── THINKING_MODE_FIX.md       # Docs on reasoning_content handling fix
├── docs/
│   └── pwsh-usage-guide.md    # PowerShell usage manual (Chinese)
└── skills/cc-menu/            # Optional CPA Cleaner & menu management scripts
    ├── SKILL.md               # Skill definition for Claude Code
    ├── bin/
    │   ├── cc-menu.sh         # Python CLI: audit, hide/show skills, manage commands
    │   ├── proxy_cpa_cleaner.py     # Local proxy: Anthropic↔OpenAI format translation, routing
    │   └── test_and_register_models.py  # Auto-discover & test CPA models
    └── docs/
        └── CPA-MultiModel-Cleaner-Guide.md
```

## Architecture

### Core Script (`cc-switch.ps1`)

Single PowerShell script providing all CLI commands. All functions are `global:` scope so they're available after dot-sourcing.

**Key functions:**
- `cc <model>` — switch model (updates all env fields in settings.json: `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL`, `fallbackModel`, `model`), then launches Claude Code with `--bare` (OAuth bypass)
- `cc` (no args) — show dynamic menu with categorized models from `availableModels`
- `cc-sync` — fetch models from CPA endpoint, diff with local, prompt to add/remove
- `cc-status` — full grouped model inventory with current model marker
- `cc-audit` — report on custom commands, hidden skills, plugin skills
- `cc-hide` / `cc-show` — toggle skill visibility via `skillOverrides` in settings.json
- `cc-profile` — switch preset (default/minimal/dev)
- `cc-commands` — list/create/remove custom slash commands (markdown files in `~/.claude/commands/`)
- `cc-theme` — list/switch Oh My Posh themes (100+ themes)
- `cc-pro` / `cc-fast` / `cc-default` — quick shortcuts to specific models

**Data flow:**
1. `Load-CCEnv` reads `~/.claude/cc-switch.env` into process environment variables
2. `Get-CCSettings` / `Save-CCSettings` read/write `~/.claude/settings.json` (JSON with depth 10)
3. `Find-ClaudeExe` searches multiple paths for `claude.exe`
4. Model switching is atomic — all 10+ model fields updated simultaneously

### Installer (`install.ps1`)

Non-destructive 5-step installer:
1. Copy `cc-switch.ps1` to `~/.claude/`
2. Copy `skills/cc-menu` to `~/.claude/skills/` (skips if exists)
3. Create `~/.claude/cc-switch.env` from `.env.example` (skips if exists)
4. Append profile block to `$PROFILE` (guarded with `# <<< cc-switch` marker, skips if already present)
5. Optionally download and install Oh My Posh, zoxide, Terminal-Icons to `C:\tools\`

### CPA Cleaner Proxy (`skills/cc-menu/bin/proxy_cpa_cleaner.py`)

Local Python HTTP proxy (port 8317) that:
1. **Cleans** messages: merges system prompts, strips Anthropic-specific fields
2. **Routes** by model name: SenseNova direct for deepseek/gpt models, CPA for others
3. **Translates** formats: Anthropic ↔ OpenAI streaming and non-streaming formats
4. **Handles thinking mode**: converts `reasoning_content` to Anthropic `thinking` content blocks with proper index management

### Profile Backup (`profile-backup.ps1`)

Optional profile with pwsh utilities: network diagnostics, file search, git shortcuts, system monitoring, aliases, enhanced prompt.

## Key Commands

### Development
```powershell
# No build step — pure PowerShell/Python, no compilation needed
# Test locally by dot-sourcing:
. .\cc-switch.ps1
cc       # show menu
cc-status  # show model inventory
```

### Testing
```powershell
# Test CPA Cleaner proxy locally:
python skills/cc-menu/bin/proxy_cpa_cleaner.py

# Test model auto-discovery:
python skills/cc-menu/bin/test_and_register_models.py
```

### Installation
```powershell
# Local install (from checkout):
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\install.ps1

# Remote install:
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex

# Skip profile reload:
.\install.ps1 -SkipProfile
```

## Configuration

### `~/.claude/cc-switch.env`
```
ANTHROPIC_API_KEY=sk-ant-xxx
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models   # optional, defaults to BASE_URL + /v1/models
```

### `~/.claude/settings.json`
Auto-managed by cc-switch. Key fields:
- `env.ANTHROPIC_MODEL` — current model
- `availableModels` — local model list (synced via `cc-sync`)
- `skillOverrides` — hidden skills (managed by `cc-hide`/`cc-profile`)
- `model`, `fallbackModel` — additional model refs

## Important Notes

- **OAuth bypass**: Model names in `cc <model>` must match entries in `availableModels` array in settings.json
- **CPA model sync**: `cc-sync` fetches from `$CPA_MODELS_URL` (or `$ANTHROPIC_BASE_URL/v1/models`), authorizes with `$ANTHROPIC_API_KEY`
- **Profile block safety**: The installer's profile block is guarded — each tool checks `Test-Path` before loading
- **Thinking mode fix**: The CPA Cleaner proxy handles `reasoning_content` → Anthropic `thinking` blocks (see `THINKING_MODE_FIX.md`)
- **No `.env` in git**: Real `.env` files are gitignored; only `.env.example` is committed
- **Python scripts** require Python 3 and are optional; core functionality is all PowerShell