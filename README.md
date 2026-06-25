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

### Auth Priority: Prefer `ANTHROPIC_AUTH_TOKEN` Over `ANTHROPIC_API_KEY`

When both `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` are set in the environment
(common in managed setups where automation tools manage `API_KEY`
while a separate CPA proxy key is provided as `AUTH_TOKEN`), cc-switch now
reads `AUTH_TOKEN` first before falling back to `API_KEY`:

```bash
# Current priority (v2.1+):
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    auth_key="***"        # 1st choice: Bearer token
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth_key="***"           # 2nd choice: API key
else
    auth_key="$(settings.json ...)"         # 3rd choice: stored config
fi
```

This prevents sending wrong credentials when multiple keys coexist in
the shell environment. The `unset ANTHROPIC_API_KEY` logic is preserved
before launching Claude Code to avoid the "Both set" warning.

### Auth Flow

| Scenario | Auth used | `ANTHROPIC_API_KEY` export | Result |
|----------|-----------|---------------------------|--------|
| Shell startup | None (`CC_SWITCH_SKIP_ENV=1` guards) | Not loaded | No conflict |
| `cc <model>` | `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer` | **Unset** before launch | No conflict |
| `claude` directly | claude.ai OAuth or settings.json | Depends on env | Normal behavior |

### Auto-Add Models
`cc <model>` automatically adds the model to `availableModels` if it's not already in the list. No need to run `cc-sync` first.

### JSON Validation
`settings.json` is validated as JSON on every read. If corrupt (empty, truncated, malformed), it's reset to `{"availableModels":[],"env":{}}`.

## ⚠ Multi-Key Environment: Avoiding Auth Conflicts

### Problem

When multiple auth variables coexist in the shell environment:

```bash
ANTHROPIC_API_KEY=***          # managed by automation tool
ANTHROPIC_AUTH_TOKEN=***       # CPA proxy key (correct one)
```

Claude Code may warn: `⚠ Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set`
and may pick the wrong key.

### Solution

cc-switch handles this with a three-layer approach:

1. **Shell startup guard** (`CC_SWITCH_SKIP_ENV=1` in `.zshrc`): prevents
   auto-loading the API key so `claude` run directly uses claude.ai OAuth.
2. **Auth key priority** (v2.1+): reads `ANTHROPIC_AUTH_TOKEN` first,
   then `ANTHROPIC_API_KEY`, then `settings.json`.
3. **Unset before launch**: `ANTHROPIC_API_KEY` is unset before invoking
   Claude Code, so the shell sees only `ANTHROPIC_AUTH_TOKEN`.

### Scenario table

| Scenario | Shell env before | Shell env at launch | Result |
|----------|-----------------|---------------------|--------|
| Shell startup | None (guard) | None | No conflict |
| `cc <model>` | Both set | Only `AUTH_TOKEN` (API_KEY unset) | No conflict ✅ |
| `claude` directly | Both set | Both set | ⚠ Warning (harmless if proxy accepts either key) |

### Unified key management (recommended pattern)

For setups with multiple key sources (automation tools + CPA proxy),
use a single `.env` file as the source of truth:

```
# ~/.openclaw/.env
CPA_API_KEY=***
CLAUDE_CODE_BASE_URL=http://127.0.0.1:8317
```

And read only these two vars in `.zshrc` (avoid sourcing the whole file):

```zsh
__cc_url="$(grep '^CLAUDE_CODE_BASE_URL=' $HOME/.openclaw/.env | cut -d= -f2-)"
__cc_key="$(grep '^CPA_API_KEY=' $HOME/.openclaw/.env | cut -d= -f2-)"
export ANTHROPIC_BASE_URL="${__cc_url:-http://127.0.0.1:8317}"
export ANTHROPIC_AUTH_TOKEN="***"
unset __cc_url __cc_key
```

Updating credentials requires editing **one file**; all consumers
(cc-switch, ccx, bare claude) pick up the change on next terminal start.

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

### CPA System Shim (port 8316)

ccx (the cross-backend launcher used by `cc`) routes CPA traffic through a
transparent system-message shim at port **8316**, which forwards to the real
CPA proxy at **8317**.

**Why this exists:** Claude Code v2.1.158+ sometimes injects `role: "system"`
messages into the *middle* of the `messages` array (e.g. auto-loaded skills
list). When CPA converts the Anthropic request to OpenAI format for strict
upstreams (Qwen, DeepSeek, GLM, etc.), those non-leading system messages
cause `400: System message must be at the beginning`.

**What the shim does:** intercepts `POST /v1/messages`, hoists stray system
messages out of the body and appends them to the top-level `system` field,
then forwards the cleaned request to the real proxy:

```
Claude Code ──→ port 8316 (shim) ──→ port 8317 (CPA)
                  │
                  ↓ detect system message in middle of array
                  ↓ extract → merge into top-level system field
                  ↓ forward to 127.0.0.1:8317
```

| Port | Service | Role |
|------|---------|------|
| **8316** | `cpa-system-shim.py` | Transparent proxy — fixes system message ordering |
| **8317** | CPA / CLIProxyAPI (Docker) | Real model proxy — routes to upstream APIs |

Without the shim, `claude` pointed directly at port 8317 works for
Anthropic models (sonnet, opus) but may fail on Qwen / DeepSeek / GLM
models with `400` errors.

### Env Cleanup: Avoiding the "Both set" Warning

When Claude Code is launched with a proxy that exposes an OpenAI-compatible
endpoint, it reads credentials from two sources:

1. **settings overlay** (via `--settings`) — typically sets `ANTHROPIC_AUTH_TOKEN`
2. **Shell environment** — may have `ANTHROPIC_API_KEY` from automation tools

If both are present, Claude Code warns:

```
⚠ Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set · auth may not work as expected
```

**Root cause:** The `set_api_key` parameter in the backend configuration controls
whether the overlay includes `ANTHROPIC_API_KEY`:

```python
BACKENDS = {
    "cpa": {
        "set_api_key": False,   # only AUTH_TOKEN in overlay → API_KEY leaks from env
    },
    "kiro": {
        "set_api_key": True,    # both in overlay → no leak
    },
}
```

When `set_api_key: False`, the overlay only provides `ANTHROPIC_AUTH_TOKEN`.
The shell env's `ANTHROPIC_API_KEY` (managed by automation) passes through
uncovered, and Claude Code sees two keys.

**Solution:** `cc-switch.sh` handles this automatically — it reads
`ANTHROPIC_AUTH_TOKEN` first (v2.1+), then **unsets** `ANTHROPIC_API_KEY`
from the shell environment before launching Claude Code:

```bash
# cc-switch.sh v2.1+ pseudocode:
# 1. Read key (AUTH_TOKEN first)
auth_key="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
# 2. Unset the conflicting env var
unset ANTHROPIC_API_KEY
# 3. Export only AUTH_TOKEN
export ANTHROPIC_AUTH_TOKEN="$auth_key"
# 4. Launch Claude Code
eval "$claude_bin"
```

If you use a different launcher (ccx, custom script), apply the same
pattern: read the key first, then strip `ANTHROPIC_API_KEY` from the
environment before `exec`/`execvp`.

See `skills/cc-menu/docs/CPA-MultiModel-Cleaner-Guide.md` for details.

---

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

---

## License

MIT
