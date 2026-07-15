# cc-switch — Claude Code Model + Menu Manager

**Cross-platform** — macOS (bash/zsh) + Windows (PowerShell)

**One-stop solution for Claude Code CLI:**
- **Model Switching** — Switch AI models + OAuth bypass (no login)
- **Auto Discovery** — `cc` auto-fetches CPA models and assigns best model per task
- **Task Scheduling** — `cc-run` uses different models for code, quick, reason, image tasks
- **Health-Aware Fallback** — Models are health-checked before assignment; `cc-run` falls back to a healthy model if the primary is unresponsive
- **Smart Health Cache** — 60s TTL cache avoids redundant API pings; sequential early-exit probing minimizes requests
- **Final Verification (v2.3.0)** — All assigned models are re-pinged before saving; cache bypassed for fresh probes; hard guard aborts if all models fail
- **Runtime 503 Detection** — `cc` captures stderr for 503/overloaded errors and suggests recovery commands
- **Hidden Error Body Detection** — `Test-ModelHealth` inspects response body for error indicators even on HTTP 200
- **Auth Priority** — `ANTHROPIC_AUTH_TOKEN` > `ANTHROPIC_API_KEY`; `API_KEY` cleared before launch to avoid "Both set" warning
- **CPA Sync** — Fetch, diff, add/remove models from your CPA proxy
- **Skill Menu Management** — Audit, hide/show, preset profiles
- **Terminal Enhancements** — Optional Oh My Posh, file icons, smart cd

Originally [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch).

---

## 🍎 macOS (bash/zsh)

```bash
curl -fsSL https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.sh | bash
# or
bash install.sh && source ~/.zshrc
```

## 🪟 Windows / PowerShell (pwsh)

*Recommended path for CPA auto-discovery and task scheduling.*

---

## Quick Start

### One-line Install

```powershell
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex
```

The installer will:
```
[1/5] Install cc-switch core script
[2/5] Install /switch slash command + cc-menu skill management
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
cc                  # Auto-discover CPA models + assign tasks + show menu
cc <model>          # Pre-switch health check → switch model → launch Claude Code
cc-run <task>       # Launch with task-optimized model (code/quick/reason/image)
cc-config           # View/override task-model assignments
cc-pro              # Switch to code task model
cc-fast             # Switch to quick task model
cc-default          # Switch to default model
cc-status           # Show current model + full list
cc-sync             # Fetch CPA models, diff with local
cc-sync --list      # Show full CPA model list only
cc-sync --force     # Auto-add new CPA models
cc-sync --remove    # Remove obsolete models
cc-sync -Reassign   # Sync + reassign task models
cc-test             # Test all models for quota/health
cc-test -RemoveDead # Remove failed models
cc-audit            # Full skill visibility report
cc-hide <skill>     # Hide a skill from Claude Code
cc-show <skill>     # Restore a hidden skill
cc-profile <preset> # Switch visibility preset (default|minimal|dev)
cc-commands list    # List custom slash commands
cc-commands create  # Create a new slash command
cc-commands remove  # Remove a slash command
cc-theme            # List/switch Oh My Posh themes
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
reads `AUTH_TOKEN` first before falling back to `API_KEY`. Additionally,
the PowerShell version (`cc-switch.ps1`) also follows this priority chain:

```powershell
# Current priority (v2.3.0+):
$authKey = if ($env:ANTHROPIC_AUTH_TOKEN) { $env:ANTHROPIC_AUTH_TOKEN }          # 1st: Bearer token
elseif ($env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY }                        # 2nd: API key
elseif ($json.env.ANTHROPIC_AUTH_TOKEN) { $json.env.ANTHROPIC_AUTH_TOKEN }        # 3rd: stored AUTH_TOKEN
else { $json.env.ANTHROPIC_API_KEY }                                              # 4th: stored API key

# Before launching claude.exe: clear API_KEY to avoid "Both set" warning
$env:ANTHROPIC_AUTH_TOKEN = $authKey
$env:ANTHROPIC_API_KEY = $null
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
ANTHROPIC_API_KEY=sk-ant-your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
# Optional: separate endpoint for model list
# CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### Usage

```powershell
# Reload profile (or restart terminal)
. $PROFILE

# Auto-discover CPA models & assign to task levels — just run cc
cc

# Then launch by task:
cc-run code         # coding → best model (auto-selected)
cc-run quick        # fast task
cc-run reason       # deep analysis
cc-run image        # image generation

# Or switch and launch directly:
cc gpt-5.5
cc claude-sonnet-4

# Quick shortcuts
cc-pro              # code task model
cc-fast             # quick task model
cc-default          # default model

# View/override task assignments
cc-config
cc-config code claude-sonnet-4.6
cc-config -Reset

# CPA model sync
cc-sync                  # fetch and diff
cc-sync -Reassign        # sync + reassign task models

# Test model health/quota
cc-test                  # test all models
cc-test -RemoveDead      # remove failed models

# Skill menu management
cc-audit             # full visibility report
cc-hide docx         # hide a skill
cc-show docx         # restore
cc-profile minimal   # switch preset

# Theme switching (Oh My Posh)
cc-theme             # list 100+ themes
cc-theme catppuccin  # switch theme (live preview)
```

---

## Installing cc-switch into Claude Code CLI

### Method A: PowerShell Profile (dot-source) — Recommended

After running `install.ps1`, cc-switch is added to your PowerShell profile. Every terminal session automatically loads it:

```powershell
# Verify it's loaded:
cc
```

Your `$PROFILE` will contain (guarded with `# >>> cc-switch` / `# <<< cc-switch`):

```powershell
# >>> cc-switch — Claude Code Model Switcher
if (Test-Path "$env:USERPROFILE\.claude\cc-switch.ps1") {
    . "$env:USERPROFILE\.claude\cc-switch.ps1"
}
# <<< cc-switch
```

### Method B: Slash Command (inside Claude Code chat)

For use inside Claude Code conversations (the `/switch` command), copy `switch.md` to your commands directory:

```powershell
# Auto-installed by install.ps1 step [2/5]
# Manual install:
copy switch.md ~\.claude\commands\switch.md
```

Then in any Claude Code session, use:
```
/switch              # List models + CPA detection
/switch gpt-5.5      # Switch model
/switch --status     # Detection summary
/switch --offline    # Local list only
```

### Method C: In-Skill (for Claude Code / OpenClaw)

The `skills/cc-menu/SKILL.md` defines Claude Code as a trigger skill. After `install.ps1` copies skills, type `/cc-menu` in Claude Code for interactive menu management (audit, hide/show skills, manage commands).

---

## Features

### 1. 🎯 CPA Auto Discovery + Task Scheduling (New)

Run `cc` with no arguments to **auto-discover all CPA models** and **intelligently assign** the best model to each task level. Each model is health-checked before assignment, and a **final verification phase** re-pings each assigned model to catch rate-limit or stale failures:

| Task | Assignment Logic | Typical Model |
|------|-----------------|---------------|
| `code` | Claude (non-haiku) → Claude → GPT → Qwen → anything | claude-sonnet-4.6 |
| `reason` | GPT-sol → GPT → Qwen-Plus/Max → Claude thinking → Claude → anything | gpt-5.6-sol |
| `quick` | DeepSeek flash → DeepSeek → GPT mini/flash → Qwen flash → Grok → anything | deepseek-v4-flash |
| `image` | image-specific → GPT → Grok image → anything | gpt-image-2 |
| `default` | GPT → DeepSeek → Claude → Qwen → anything | gpt-5.5 |

**Health guarantee:** All 5 task models are **always re-pinged** before saving (cache bypassed via `$script:CC_HEALTH_CACHE.Remove`). If a model fails verification, the next candidate in the priority chain is probed (also bypassing cache). If all 5 tasks lose their model, the hard guard aborts without modifying `settings.json`. The "anything" fallback is limited to the first 20 models to avoid probing 150+ models.

The assignment is saved to `settings.json → taskModels` and used by `cc-run`:

```powershell
# All use different models automatically
cc-run code        # coding
cc-run quick       # simple/fast
cc-run reason      # deep analysis
cc-run image       # image generation
```

**Health-aware fallback:** Before launching, `cc-run` **bypasses the health cache** (always does a fresh probe) to catch rate-limited or stale models. If the assigned model is unresponsive, it searches for a healthy fallback within the same vendor category first, then across all available models (also bypassing cache at each step).

View and override with `cc-config`:

```powershell
cc-config                          # show assignments
cc-config code gpt-5.5             # override code task
cc-config -Reset                   # re-run auto-discovery
cc-sync -Reassign                  # sync + reassign
```

### 2. Model Switching + OAuth Bypass

Launches Claude Code directly with API key auth (no login prompt):

```powershell
cc claude-sonnet-4
cc deepseek-v4-flash
cc gpt-5.5
```

### 3. Dynamic Model Menu

The `cc` menu reads `availableModels` from `settings.json` and auto-categorizes by provider:

```
Current: gpt-5.5

GPT:        gpt-5.5  gpt-5.4-mini  gpt-5.3-codex
Claude:     claude-sonnet-4.6  claude-opus-4-7
DeepSeek:   deepseek-v4-flash  deepseek-v4-flash-free
Grok:       grok-4.20-auto  grok-4.20-fast
...

Task assignments (cc-config to change):
  code    → claude-sonnet-4.6
  quick   → deepseek-v4-flash
  reason  → gpt-5.6-sol
  image   → gpt-image-2
  default → gpt-5.5
```

### 4. CPA Model Sync

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
| `-Reassign` | Sync + re-assign task models |

### 5. Skill Menu Management

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

### 6. Secret Management via `.env`

| File | Contains | Git? |
|------|----------|------|
| `.env.example` | Placeholders | Yes |
| `~/.claude/cc-switch.env` | Real API key + CPA URL | No (`.gitignore`) |

### 7. Terminal Enhancements (Optional)

Installed via step [5/5] of the installer:

| Tool | Version | Effect |
|------|---------|--------|
| **Oh My Posh** | v29+ | Colored prompt with git status, execution time |
| **Terminal-Icons** | latest | File/folder icons in `ls` |
| **zoxide** | v0.9+ | Smart `cd` — learns your directories |

```powershell
cc-theme                    # list 100+ themes
cc-theme catppuccin         # switch live (preview)
```

---

## Platform Support

cc-switch works with **any API-compatible inference platform**. Configure via `~/.claude/cc-switch.env`:

### CPA Proxy (Recommended)

```bash
ANTHROPIC_API_KEY=sk-ant-your-key
ANTHROPIC_BASE_URL=https://your-cpa-instance.com/
```

The CPA proxy provides a unified API gateway with model routing, quota management, and format translation.

### OpenAI / Azure OpenAI

```bash
ANTHROPIC_API_KEY=sk-your-openai-key
ANTHROPIC_BASE_URL=https://api.openai.com/v1
# Separate model list URL for platforms with different endpoints
CPA_MODELS_URL=https://api.openai.com/v1/models
```

### Local Inference (Ollama / vLLM / LM Studio)

```bash
ANTHROPIC_API_KEY=not-needed
ANTHROPIC_BASE_URL=http://localhost:11434/v1
```

### Custom API Gateway (Kong / Tyk / Custom Proxy)

```bash
ANTHROPIC_API_KEY=your-gateway-key
ANTHROPIC_BASE_URL=https://your-gateway.com/anthropic
CPA_MODELS_URL=https://your-gateway.com/models
```

### Behind the scenes

cc-switch sends Anthropic-format requests (`/v1/messages`). The CPA Cleaner proxy (`proxy_cpa_cleaner.py`) can translate between Anthropic ↔ OpenAI formats if your endpoint only supports OpenAI format.

---

## CPA Cleaner Proxy (Advanced: Smart Router + Format Translation)

The optional Python proxy (port 8317) provides **intelligent task-based model routing** — analyzes each request's content and routes to the optimal model transparently:

| Task Type | Routed Model | Trigger Keywords |
|-----------|-------------|-----------------|
| `coding` | claude-sonnet-4.6 | code, implement, bug, fix, git, api, sql, deploy |
| `reason` | gpt-5.6-sol | analyze, compare, explain, evaluate, think step by step |
| `image` | gpt-image-2 | draw, create image, generate image, illustrate |
| `quick` | deepseek-v4-flash | translate, convert, hello, simple |
| `default` | keep original model | everything else |

### Setup

```powershell
# Start local proxy (port 8317)
cc-menu cleaner start

# Set in .env
ANTHROPIC_BASE_URL=http://127.0.0.1:8317
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

**Solution:** read the key first, then strip `ANTHROPIC_API_KEY` from the
environment before `exec`/`execvp`, exporting only `ANTHROPIC_AUTH_TOKEN`.

### Disable Smart Routing

```bash
CPA_SMART_ROUTING=false
```

### How It Works

```
Claude Code
    ↓
Smart Router Proxy (localhost:8317)
    ↓ analyzes messages content
    ├── "fix this bug"      → claude-sonnet-4.6
    ├── "分析这两个方案"     → gpt-5.6-sol
    ├── "画一只猫"          → gpt-image-2
    └── "hello world"       → deepseek-v4-flash
    ↓
CPA Proxy (your inference endpoint)
```

### Quota-Aware Fallback

- **3 consecutive quota errors** (HTTP 429/403/402) → model marked **unhealthy**
- Subsequent requests try the **next fallback** in chain
- After **120 seconds** → auto-recovery
- Each task type has its own fallback chain

Example fallback chain for `coding`:
```
claude-sonnet-4.6 → gpt-5.5 → deepseek-v4-flash → qwen3.6-plus
```

See `skills/cc-menu/docs/CPA-MultiModel-Cleaner-Guide.md` for details.

---

## Configuration

### `~/.claude/cc-switch.env` (secrets)

```bash
# Required
ANTHROPIC_API_KEY=sk-ant-xxx
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/

# Optional: separate endpoint for model list
# CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### `settings.json` (auto-managed by cc-switch)

Path: `~/.claude/settings.json`

| Field | Managed By | Purpose |
|-------|-----------|---------|
| `env.ANTHROPIC_MODEL` | `cc <model>` | Current model for Claude Code |
| `availableModels` | `cc-sync` | Local model list synced from CPA |
| `taskModels` | `cc`, `cc-config` | Task-to-model assignments (code/quick/reason/image/default) |
| `skillOverrides` | `cc-hide`/`cc-show`/`cc-profile` | Hidden skills control |
| `env.ANTHROPIC_API_KEY` | `.env` fallback | API key fallback |
| `env.ANTHROPIC_BASE_URL` | `.env` fallback | Endpoint fallback |

---

## Project Structure

```
cc-switch/
├── cc-switch.sh               # Core functions: model switch + menu + theme (bash/zsh, 854 lines)
├── cc-switch.ps1              # Core: model switch + auto-discovery + health cache + menu + theme (PowerShell, ~1516 lines)
├── install.sh                 # macOS installer (bash)
├── install.ps1                # Windows/pwsh 5-step installer
├── profile-backup.ps1         # Optional pwsh utilities
├── .env.example               # Secret template
├── .gitignore
├── LICENSE
├── README.md
├── switch.md                  # Slash command reference (/switch, cross-platform)
├── THINKING_MODE_FIX.md       # reasoning_content → Anthropic thinking blocks fix
├── docs/
│   └── pwsh-usage-guide.md    # PowerShell usage manual (Chinese)
├── .claude/
│   └── settings.local.json    # Claude Code permission overrides
└── skills/cc-menu/
    ├── SKILL.md               # Claude Code skill definition
    ├── bin/
    │   ├── cc-menu.sh         # Shell CLI: audit, hide/show skills
    │   ├── proxy_cpa_cleaner.py     # Anthropic↔OpenAI proxy + smart router
    │   └── test_and_register_models.py
    └── docs/
        └── CPA-MultiModel-Cleaner-Guide.md
```

---

## Command Reference

| Command | Description |
|---------|-------------|
| `cc` | Auto-discover CPA models + assign tasks + show menu |
| `cc <model>` | Pre-switch health check → atomic model switch (updates 10+ fields), then launches `claude.exe --bare` with stderr capture for 503 detection |
| `cc-run <task>` | Launch with task-optimized model (code/quick/reason/image) |
| `cc-config` | View current task-model assignments |
| `cc-config <task> <model>` | Override task model |
| `cc-config -Reset` | Re-run CPA auto-discovery |
| `cc-status` | Full model inventory with task assignments |
| `cc-sync` | Sync model list from CPA |
| `cc-sync -Reassign` | Sync + reassign task models |
| `cc-test` | Test all models for quota/health |
| `cc-test -RemoveDead` | Remove failed models |
| `cc-pro` | Switch to code task model |
| `cc-fast` | Switch to quick task model |
| `cc-default` | Switch to default model |
| `cc-audit` | Audit skill visibility |
| `cc-hide <skill>` | Hide skill |
| `cc-show <skill>` | Restore hidden skill |
| `cc-profile <name>` | Switch preset (default/minimal/dev) |
| `cc-commands` | Manage custom slash commands |
| `cc-theme` | List/switch Oh My Posh themes |

---

## Related

- Original: [luyuehm/cc-switch](https://github.com/luyuehm/cc-switch)
- Hermes Agent: [hermes-agent.nousresearch.com](https://hermes-agent.nousresearch.com/docs)

---

## License

MIT
