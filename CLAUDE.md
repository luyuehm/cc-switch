# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**cc-switch** — PowerShell-based Claude Code CLI manager. One script (`cc-switch.ps1`) provides model switching with OAuth bypass, dynamic model menu, CPA proxy model sync, skill menu management, Oh My Posh theme switching, and model health testing. An optional Python-based CPA Cleaner proxy handles Anthropic↔OpenAI format translation with smart task routing and quota-aware fallback.

## Architecture

### Core Script (`cc-switch.ps1`) — ~1390 lines

Single PowerShell file. All functions are `global:` scope for availability after dot-sourcing. No build step.

**Startup chain:**
1. `Load-CCEnv` — reads `~/.claude/cc-switch.env` into process env vars at import time
2. `Get-CCSettings` / `Save-CCSettings` — read/write `~/.claude/settings.json` (ConvertFrom-Json, depth 10)
3. `Find-ClaudeExe` — searches `~/.local/bin/claude.exe`, then `LOCALAPPDATA`, then `APPDATA/npm`

**Model categorization helpers:**
- `Get-ModelCategory` — single source of truth for vendor prefix regex (centralized, used by 6+ functions)
- `Group-ModelsByCategory` — batch categorize a list into `@{ "GPT" = [...], "Claude" = [...] }` hashtable
- `Get-CategorySortOrder` — deterministic display order for vendor categories

**Health cache:**
- `$script:CC_HEALTH_CACHE` — in-memory cache with 60s TTL, avoids redundant API pings
- `Test-ModelHealth` — checks cache first, then pings API, caches result
- `Select-HealthyModel` — sequential testing with early exit (tests in priority order, stops at first healthy). Uses cache to skip previously-failed models. **Greatly reduces API calls compared to old parallel-all approach.**
- `Clear-StaleHealthCache` — purges expired entries before a fresh auto-assign

**CPA auto-discovery:**
- `Get-CPAModelList` — fetches model list from CPA endpoint, shared by `cc`, `cc-sync`, and `Invoke-CCAutoAssign`
- `Invoke-CCAutoAssign` — categorizes models by vendor prefix via `Group-ModelsByCategory`, then intelligently assigns the best model to each task type (sequential health probing with shared cache across task groups):
  - `code` → Claude non-haiku → Claude → GPT → Qwen → anything
  - `reason` → GPT sol/reasoning → GPT → Qwen Plus/Max → Claude thinking → Claude → anything
  - `quick` → DeepSeek flash → DeepSeek → GPT mini/flash → Qwen flash → Grok → anything
  - `image` → image-specific → GPT → Grok image → anything
  - `default` → GPT → DeepSeek → Claude → Qwen → anything
- Results saved to `settings.json → taskModels`

**Command functions (all callable after dot-sourcing):**

| Function | Purpose |
|----------|---------|
| `cc <model>` | Atomic model switch (updates 10+ fields: all `ANTHROPIC_DEFAULT_*`, `fallbackModel`, `model`), then launches `claude.exe --bare` |
| `cc` (no args) | **Auto-discovers CPA models**, assigns best model per task, saves to `settings.json → taskModels`, then shows `Show-CCMenu` |
| `cc-run <task>` | Task-smart launch from `settings.json.taskModels`: `code`, `quick`, `reason`, `image`, `default`. Falls back to heuristic from `availableModels` if no assignment exists. Can also pass a raw model name |
| `cc-config [-Reset]` | View current `taskModels` assignment. `-Reset` re-runs CPA auto-discovery. `cc-config <task> <model>` overrides a specific task |
| `cc-sync [-List] [-Force] [-Remove] [-Reassign]` | Fetch models from CPA endpoint, diff with local `availableModels`, prompt to add/remove. `-Reassign` re-runs auto-assignment after sync |
| `cc-test [-RemoveDead] [-Timeout N] [-Parallel N]` | Parallel health test pinging each model with `Invoke-RestMethod -Parallel`, classifies as healthy/quota/failed |
| `cc-audit` | Full report: custom commands (markdown files in `~/.claude/commands/`), hidden skills in `skillOverrides`, enabled plugin packages |
| `cc-hide <name>` / `cc-show <name>` | Set `skillOverrides.<name> = "off"` or remove entry. Supports plugin wildcard (`document-skills:*`) |
| `cc-profile default\|minimal\|dev` | Bulk set `skillOverrides` to preset configurations |
| `cc-commands list\|create\|remove` | Manage custom slash commands (markdown frontmatter in `~/.claude/commands/`) |
| `cc-theme <name>` | List or switch Oh My Posh themes (100+ `.omp.json` files). Live preview via `oh-my-posh init pwsh --config` |
| `cc-pro` / `cc-fast` / `cc-default` | Shortcuts: claude-opus-4-7 / deepseek-v4-flash / gpt-5.5 |
| `Get-CCModel` | Returns current model name from settings.json |

**Model switching atomicity** — all 10+ fields updated in a single `Save-CCSettings` call. Claude Code launched with `--bare` flag for OAuth bypass. API key resolved from process env (loaded from `.env`) then falls back to `settings.json` values.

**Model inventory UI** — models are grouped by vendor prefix regex (gpt/o\d → GPT, claude/sonnet/haiku → Claude, deepseek → DeepSeek, qwen → Qwen, grok → Grok, kimi/moonshot → Moonshot, llama → Llama, mistral → Mistral, gemin → Gemini, step → Stepfun). The same grouping is used in `cc-status` and `cc-sync` display.

### CPA Cleaner Proxy (`skills/cc-menu/bin/proxy_cpa_cleaner.py`) — ~48K

Local Python HTTP proxy on port 8317 that provides:

1. **Format translation** — Anthropic ↔ OpenAI streaming and non-streaming. Handles system prompt merging, tool_use blocks, content block indices
2. **Smart task routing** — analyzes request content for keywords and routes to task-optimized models (coding→claude-sonnet-4.6, reason→gpt-5.6-sol, image→gpt-image-2, quick→deepseek-v4-flash). Disabled via `CPA_SMART_ROUTING=false`
3. **Quota-aware fallback** — tracks model health. 3 consecutive quota errors (429/403/402) marks model unhealthy, falls back through chain. Auto-recovers after 120s
4. **Thinking mode** — converts OpenAI `reasoning_content` to Anthropic `thinking` content blocks with proper index management (thinking=0, text=1, tool_use=2+). See `THINKING_MODE_FIX.md`

### Installer (`install.ps1`) — 5-step non-destructive

1. Copy `cc-switch.ps1` to `~/.claude/` (always)
2. Copy `skills/cc-menu` to `~/.claude/skills/` (skips if exists)
3. Create `~/.claude/cc-switch.env` from `.env.example` (skips if exists)
4. Append guarded profile block to `$PROFILE` (bounded by `# >>> cc-switch` / `# <<< cc-switch`, skips if marker found)
5. Optionally download Oh My Posh, zoxide, Terminal-Icons to `C:\tools\`

### Permission Model

`.claude/settings.local.json` grants Claude Code permission to run `cc-run *` via PowerShell (the only approved shell command).

### Skill Management System

Skills managed via `settings.json` fields:
- `skillOverrides` — object with `"<name>": "off"` for hidden skills, `"user-invocable-only"` for menu-only, `"name-only"` for name-only visibility
- `enabledPlugins` — auto-detected plugin packages (e.g., `document-skills`, `financial-analysis`)
- Custom commands live as markdown files in `~/.claude/commands/` with YAML frontmatter (`description`, `argument-hint`)

**Presets:**
- `default`: no `skillOverrides` (all visible)
- `minimal`: hide docs/examples, financial/pitch→menu-only
- `dev`: hide all except claude-api→menu-only

## Key Files

```
cc-switch/
├── cc-switch.ps1              # Core: model switch + menu + theme + skill management (941 lines)
├── install.ps1                # 5-step installer
├── profile-backup.ps1         # Optional pwsh utilities: network, git, system, aliases
├── .env.example               # Secret template (ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, CPA_MODELS_URL)
├── .gitignore                 # Excludes .env files
├── README.md                  # Full documentation
├── switch.md                  # Slash command reference for Claude Code
├── THINKING_MODE_FIX.md       # reasoning_content → Anthropic thinking blocks fix
├── docs/pwsh-usage-guide.md   # PowerShell usage manual (Chinese)
├── .claude/
│   └── settings.local.json    # Claude Code permission overrides
└── skills/cc-menu/
    ├── SKILL.md               # Skill definition for Claude Code
    ├── bin/
    │   ├── cc-menu.sh         # Shell CLI: audit, hide/show skills, manage commands
    │   ├── proxy_cpa_cleaner.py     # Anthropic↔OpenAI proxy with smart routing
    │   └── test_and_register_models.py  # Auto-discover & test CPA models
    └── docs/
        └── CPA-MultiModel-Cleaner-Guide.md
```

## Key Commands

### Development (no build step)
```powershell
# Dot-source and test
. .\cc-switch.ps1
cc                    # show dynamic menu
cc-status             # grouped model inventory
cc gpt-5.5            # switch model + launch Claude Code
cc-run code           # task-smart launch
```

### Testing
```powershell
# Test CPA Cleaner proxy
python skills/cc-menu/bin/proxy_cpa_cleaner.py

# Test model auto-discovery
python skills/cc-menu/bin/test_and_register_models.py
```

### Installation
```powershell
# From checkout
.\install.ps1
.\install.ps1 -SkipProfile   # skip profile modification

# Remote
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex
```

## Configuration

### `~/.claude/cc-switch.env` (secrets, gitignored)
```
ANTHROPIC_API_KEY=sk-ant-xxx
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models   # optional
```

### `~/.claude/settings.json` (auto-managed)
- `env.ANTHROPIC_MODEL` — current model
- `availableModels` — model list (synced via `cc-sync`)
- `taskModels` — task-to-model assignments (set by `cc` auto-discovery or `cc-config`)
- `skillOverrides` — hidden skills (`cc-hide`/`cc-profile`)
- `model`, `fallbackModel` — additional model refs (all switched atomically)

## Important Notes

- **Model names** in `cc <model>` must match entries in `availableModels` array exactly
- **API key resolution**: process env (from `.env`) → `settings.json.env.ANTHROPIC_API_KEY`
- **`cc-sync`** fetches from `CPA_MODELS_URL`, falls back to `ANTHROPIC_BASE_URL/v1/models`, authorizes with `ANTHROPIC_API_KEY`
- **Oh My Posh** expects themes at `C:\tools\oh-my-posh\themes\*.omp.json`
- **Python scripts** require Python 3 and are optional; core is all PowerShell
- **CPA Cleaner** runs on localhost:8317, set `ANTHROPIC_BASE_URL=http://127.0.0.1:8317` to use