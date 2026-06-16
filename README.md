# cc-switch — Claude Code Model + Menu Manager

**One-stop solution for Claude Code CLI:**
- **Model Switching**: Switch AI models + OAuth bypass (no login)
- **Dynamic Menu**: Model list auto-updates from your available models
- **CPA Sync**: Fetch, diff, add/remove models from your CPA proxy
- **Skill Menu Management**: Audit, hide/show, preset profiles
- **Secret Management**: `.env` based API key config
- **Terminal Enhancements**: Optional Oh My Posh, file icons, smart cd

*100% PowerShell — works on Windows (pwsh)*

---

## Quick Start

### One-line Install

```powershell
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex
```

The installer will:
```
[1/5] Install cc-switch core script
[2/5] Install cc-menu skill management
[3/5] Configure .env secrets
[4/5] Update PowerShell profile
[5/5] Ask to install pwsh terminal enhancements (Oh My Posh + zoxide + Terminal-Icons)
```

Say **Y** at step [5/5] for a full oh-my-zsh-like experience. Say N for minimal install.

### Configure Secrets

Edit `~/.claude/cc-switch.env`:

```bash
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
# Optional: separate endpoint for model list
# CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### Manual Install

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# From local checkout:
. .\install.ps1
```

### Usage

```powershell
# Reload profile
. $PROFILE

# Show menu (dynamic model list)
cc

# Switch model + launch Claude Code
cc gpt-5.5
cc claude-sonnet-4

# Quick shortcuts
cc-pro         # claude-opus-4-7
cc-fast        # deepseek-v4-flash
cc-default     # gpt-5.5

# CPA model sync
cc-sync              # fetch and diff
cc-sync -List        # show full CPA model list only
cc-sync -Force       # auto-add new models
cc-sync -Remove      # auto-remove obsolete models

# Skill menu management
cc-audit             # full visibility report
cc-hide docx         # hide a skill
cc-hide document-skills:*  # hide entire plugin
cc-show docx         # restore
cc-profile minimal   # switch preset
cc-commands          # list/manage custom commands

# Theme switching (Oh My Posh)
cc-theme             # list 100+ themes
cc-theme catppuccin  # switch theme (live preview)
```

---

## Features

### 1. Model Switching + OAuth Bypass

Launches Claude Code directly with API key auth (no login prompt):

```powershell
cc claude-sonnet-4
cc deepseek-v4-flash
cc gpt-5.5
```

### 2. Dynamic Model Menu

The `cc` menu no longer has hardcoded model names. It reads `availableModels` from `settings.json` and auto-categorizes models by provider:

```
Current: gpt-5.5

GPT:        gpt-5.5  gpt-5.4-mini  gpt-5.3-codex
Claude:     claude-sonnet-4.6  claude-opus-4-7
DeepSeek:   deepseek-v4-flash  deepseek-v4-flash-free
Grok:       grok-4.20-auto  grok-4.20-fast
...
```

After `cc-sync`, the menu updates automatically.

### 3. CPA Model Sync

```powershell
cc-sync
# 1. Fetches models from CPA endpoint
# 2. Shows categorized model list with counts per provider
# 3. Shows diff: +N new, -N gone
# 4. Prompts to add new models / remove obsolete ones
```

| Flag | Effect |
|------|--------|
| `(none)` | Fetch + diff + confirm before adding |
| `-List` | Show full model list only, no sync |
| `-Force` | Auto-add new models without prompt |
| `-Remove` | Remove models no longer on CPA |

### 4. Skill Menu Management

Integrated from cc-menu:

| Command | Description |
|---------|-------------|
| `cc-audit` | Full report: custom commands, hidden skills, plugins |
| `cc-hide <skill>` | Hide skill (e.g., `docx`, `document-skills:*`) |
| `cc-show <skill>` | Restore hidden skill |
| `cc-profile <name>` | Switch preset: `default`, `minimal`, `dev` |
| `cc-commands` | List/create/remove custom `/` commands |

**Presets:**

| Profile | Effect |
|---------|--------|
| `default` | All skills visible |
| `minimal` | Hide docs/examples, financial/pitch only |
| `dev` | Dev skills only, rest hidden |

### 5. Secret Management via `.env`

| File | Contains | Git? |
|------|----------|------|
| `.env.example` | Placeholders | Yes |
| `~/.claude/cc-switch.env` | Real API key + CPA URL | No (`.gitignore`) |

### 6. Terminal Enhancements (Optional)

Installed via step [5/5] of the installer:

| Tool | Version | Effect |
|------|---------|--------|
| **Oh My Posh** | v29.x | Colored prompt with git status, execution time |
| **Terminal-Icons** | latest | File/folder icons in `ls` |
| **zoxide** | v0.9.9 | Smart `cd` — learns your directories |

**Theme switching:**

```powershell
cc-theme                    # list 100+ themes
cc-theme catppuccin         # switch live (preview)
cc-theme powerlevel10k_classic
cc-theme montys
cc-theme tokyonight_storm
```

Popular themes marked with `=>` in the list. To make permanent, edit `$PROFILE` and update the `$poshTheme` path.

---

## Configuration

### `~/.claude/cc-switch.env`

```bash
# Required: API key for auth
ANTHROPIC_API_KEY=sk-ant-xxx

# Required: Model inference endpoint (CPA proxy or direct API)
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/

# Optional: Separate endpoint for model list
# CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### `settings.json` (auto-managed by cc-switch)

cc-switch reads/writes `~/.claude/settings.json`:

- `env.ANTHROPIC_MODEL`: Current model
- `env.ANTHROPIC_API_KEY`: Fallback if `.env` not set
- `env.ANTHROPIC_BASE_URL`: Fallback if `.env` not set
- `availableModels`: Local model list (synced via `cc-sync`)
- `skillOverrides`: Hidden skills (managed by `cc-hide`/`cc-profile`)

---

## Installer Details

Running `install.ps1` does:

```
[1/5] Copy cc-switch.ps1 to ~/.claude/
[2/5] Copy cc-menu skills to ~/.claude/skills/
[3/5] Create ~/.claude/cc-switch.env from template
[4/5] Add Oh My Posh + Terminal-Icons + zoxide guards to $PROFILE
[5/5] Optionally download and install pwsh tools (20 MB total)
```

Profile block added (safe — guards check if each tool exists):

```powershell
# Oh My Posh (prompt theme)
if (Test-Path "C:\tools\oh-my-posh.exe") { ... }

# Terminal Icons
if (Get-Module -ListAvailable -Name Terminal-Icons) { ... }

# zoxide (smart cd)
if (Test-Path "C:\tools\zoxide.exe") { ... }

# cc-switch core
. $env:USERPROFILE\.claude\cc-switch.ps1
```

---

## Advanced: CPA Cleaner Proxy

cc-switch includes cc-menu's CPA Cleaner for advanced routing:

```powershell
# Start local proxy (port 8317)
cc-menu cleaner start

# Set in .env
ANTHROPIC_BASE_URL=http://127.0.0.1:8317

# Test and register models
cc-menu cleaner test
```

See `skills/cc-menu/docs/CPA-MultiModel-Cleaner-Guide.md` for details.

---

## Project Structure

```
cc-switch/
├── cc-switch.ps1          # Core: model switch + menu + theme
├── install.ps1            # 5-step installer (with optional pwsh tools)
├── .env.example           # Secret template
├── .gitignore             # Excludes .env
├── README.md
├── switch.md              # Slash command reference
└── skills/cc-menu/        # CPA Cleaner scripts
    ├── SKILL.md
    ├── bin/
    │   ├── cc-menu.sh
    │   ├── proxy_cpa_cleaner.py
    │   └── test_and_register_models.py
    └── docs/
        └── CPA-MultiModel-Cleaner-Guide.md
```

---

## Related

- **Hermes Agent**: https://hermes-agent.nousresearch.com/docs

---

## License

MIT