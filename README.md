# cc-switch — Claude Code Model + Menu Manager

**One-stop solution for Claude Code CLI:**
- **Model Switching**: Switch AI models + OAuth bypass (no login)
- **Skill Menu Management**: Audit, hide/show, preset profiles
- **CPA Sync**: Auto-fetch available models from your CPA proxy
- **Secret Management**: `.env` based API key config

*100% PowerShell — works on Windows, macOS, Linux*

---

## Quick Start

### One-line Install

```powershell
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex
```

### Configure Secrets

Edit `~/.claude/cc-switch.env`:

```bash
ANTHROPIC_API_KEY=your-api-key-here
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/
# Optional: separate endpoint for model list
# CPA_MODELS_URL=https://your-cpa-proxy.com/v1/models
```

### Usage

```powershell
# Reload profile
. $PROFILE

# Switch model + launch Claude Code
cc gpt-5.5

# Show menu
cc

# Quick shortcuts
cc-pro         # claude-opus-4-7
cc-fast        # deepseek-v4-flash
cc-default     # gpt-5.5

# Sync models from CPA
cc-sync        # fetch and diff
cc-sync -Force # auto-add new models

# Skill menu management
cc-audit           # audit visibility
cc-hide docx       # hide a skill
cc-hide document-skills:*  # hide entire plugin
cc-show docx       # restore
cc-profile minimal # switch to minimal preset
cc-commands        # list custom commands
```

---

## Features

### 1. Model Switching + OAuth Bypass

No more login prompts — launches directly with API key auth:

```powershell
cc claude-sonnet-4
cc deepseek-v4-flash
cc gpt-5.5
```

### 2. CPA Model Sync

Automatically fetch available models from your CPA proxy:

```powershell
cc-sync
# Shows: CPA total, Local count, New models (+N), Gone models (-N)
# Confirms before adding new ones (use -Force to auto-add)
```

### 3. Skill Menu Management

Integrates cc-menu functionality:

| Command | Description |
|---------|-------------|
| `cc-audit` | Full report: custom commands, hidden skills, plugins |
| `cc-hide <skill>` | Hide skill (e.g., `docx`, `document-skills:*`) |
| `cc-show <skill>` | Restore hidden skill |
| `cc-profile <name>` | Switch preset: `default`, `minimal`, `dev`, `custom` |
| `cc-commands list` | List custom `/` commands |
| `cc-commands create <name> <desc>` | Create new custom command |
| `cc-commands remove <name>` | Delete custom command |

**Presets:**

| Profile | Effect |
|---------|--------|
| `default` | All skills visible |
| `minimal` | Hide docs/examples, financial/pitch menu-only |
| `dev` | Dev skills only, rest hidden |
| `custom` | Manual edit `settings.json` |

### 4. Secret Management via `.env`

| File | Contains | Git? |
|------|----------|------|
| `.env.example` | Placeholders | ✅ Yes |
| `~/.claude/cc-switch.env` | Real API key + CPA URL | ❌ No (`.gitignore`) |

---

## Configuration

### `~/.claude/cc-switch.env`

```bash
# Required: API key for auth
ANTHROPIC_API_KEY=sk-ant-xxx

# Required: Model inference endpoint (CPA proxy or direct API)
ANTHROPIC_BASE_URL=https://your-cpa-proxy.com/

# Optional: Separate endpoint for model list (defaults to BASE_URL/v1/models)
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

## Advanced: CPA Cleaner Proxy (Optional)

cc-switch includes cc-menu's CPA Cleaner for advanced routing:

```powershell
# Start local proxy (port 8317)
cc-menu cleaner start

# Set in ~/.claude/cc-switch.env
ANTHROPIC_BASE_URL=http://127.0.0.1:8317

# Test and register models
cc-menu cleaner test
```

See `skills/cc-menu/docs/CPA-MultiModel-Cleaner-Guide.md` for details.

---

## Project Structure

```
cc-switch/
├── cc-switch.ps1          # Core: model switch + menu management
├── install.ps1            # One-click installer
├── .env.example           # Secret template
├── README.md
└── skills/cc-menu/        # Optional: advanced CPA Cleaner
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