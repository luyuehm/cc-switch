# cc-switch — Claude Code Model Switcher for PowerShell

Zero-friction model switching for Claude Code on Windows. Switch models before launch, bypass OAuth login, all from your pwsh terminal.

## Features

- **Pre-launch switching** — change model THEN start Claude Code, one command
- **OAuth bypass** — injects API key via env vars, no browser login needed
- **Shorthand aliases** — `cc-pro`, `cc-fast`, `cc-default` for common models
- **Status dashboard** — `cc-status` shows grouped model inventory with current marker
- **CPA-aware** — `/switch` slash command syncs with cliproxyapi endpoint
- **Offline mode** — `/switch --offline` works from local cache only

## Quick Install

```powershell
irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex
```

Or manual:

```powershell
git clone https://github.com/luyuehm/cc-switch.git
cd cc-switch
.\install.ps1
```

## Usage

```powershell
# Reload profile after install (or restart pwsh)
. $PROFILE

# Switch model and launch Claude Code
cc gpt-5.5

# Show current model and available shortcuts
cc

# Show full grouped model inventory
cc-status

# Quick shortcuts
cc-pro         # claude-opus-4-7
cc-fast        # deepseek-v4-flash
cc-default     # gpt-5.5
```

## Claude Code Slash Command

Copy `switch.md` to your Claude Code commands directory:

```powershell
cp switch.md $env:USERPROFILE\.claude\commands\
```

Then inside Claude Code:

```
/switch                  # list models with CPA detection
/switch gpt-5.5          # switch to GPT-5.5
/switch --offline        # list from local cache only
/switch --status         # CPA detection summary only
```

## Requirements

- PowerShell 7+ (pwsh)
- Claude Code CLI installed (any version)
- API key configured in `~/.claude/settings.json`

## Files

| File | Purpose |
|------|---------|
| `cc-switch.ps1` | Standalone script, dot-source to load functions |
| `install.ps1` | Copies profile functions and switch.md to correct locations |
| `switch.md` | Claude Code `/switch` slash command |
| `Microsoft.PowerShell_profile.ps1` | Reference: full profile entry (what install.ps1 writes) |

## License

MIT
