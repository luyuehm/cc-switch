# Changelog

All notable changes to cc-switch. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each version maps to a git tag.

## [v2.5.0] — 2026-09-24

Shell-startup and prompt release. The macOS path (`cc-switch.sh`, `install.sh`) is unchanged — the `v2.4.0` label in that script still describes the macOS feature set.

### Added

- **`skills/pwsh-startup-hang-fix/`** — Windows counterpart to `shell-startup-hang-fix` (trigger `/pwshfix`). Covers the three root causes measured on pwsh 7.6.6:
  - *Eager module import* — Terminal-Icons parses ~780 KB and rewrites ~180 KB of theme XML on every load (~705 ms).
  - *Network self-check* — `oh-my-posh init` runs notice/upgrade checks per shell (1618 ms → 83 ms once disabled).
  - *PATH shadowing* — a non-idempotent `$env:Path +=` both duplicated the entry and left it at the tail, so an old v25 MSI outranked the pinned v29.
  - Plus the interleaved A/B **median** methodology (single-shot A/B gave contradictory numbers under load) and the case-insensitivity traps (`Set-Alias prompt Get-Prompt`, `Set-Alias grep Grep`).
- **`docs/pwsh-usage-guide.md`** — new sections *Prompt 引擎与启动优化* and *已修复的问题*, with a before/after baseline table.
- **`CHANGELOG.md`** — this file.

### Added (prompt)

- **`$PromptEngine`** selector — `native` (default, in-process powerlevel10k replica, ~2–23 ms per prompt) or `omp` (oh-my-posh, ~90 ms because it spawns `oh-my-posh.exe` per Enter). The default only applies when the variable is unset, so a runtime switch survives re-sourcing the profile.

### Fixed

- **`profile-backup.ps1` — startup 1083 ms → ~250–350 ms:**
  - Terminal-Icons is no longer imported at startup; `Get-ChildItem` is shadowed and the module loads on first file listing (−~705 ms).
  - `oh-my-posh disable notice` + `disable upgrade`; `init` 1618 ms → 83 ms.
  - PATH normalisation is idempotent (de-duplicate + prepend `C:\tools`) — no unbounded growth, no old-version shadowing.
  - The native prompt draws the second line's `─╯` with ESC7/ESC8 so the real cursor never moves and PSReadLine editing still works; `.git/HEAD` is read directly (~2 ms) and dirty counts are TTL-cached (~130 ms per uncached `git status`).
- **Broken shell utilities:**
  - `Grep` — `-Path` gained `Position=1`, so `Grep "pattern" .\src` binds; the dead `-IgnoreCase` flag is documented as a no-op.
  - `GrepR` — no longer passes `-Recurse` to `Select-String` (which has no such parameter); recursion comes from `Get-ChildItem`.
  - `Get-PingStats` — reads `PingReply.Latency` on PowerShell 7 and no longer computes a standard deviation from a single sample.
  - `Get-SystemInfo` — skips zero-capacity mounts instead of dividing by zero.
  - `ll` / `lsa` / `vi` / `vim` — converted from `Set-Alias` definitions that carried arguments (which cannot work) to functions.
  - Removed `Set-Alias grep Grep` (self-shadowing: the alias and the function are the same case-insensitive name) and `Set-Alias prompt Get-Prompt` (`prompt` is a reserved function).
- **`install.ps1`** — installs the new `/pwshfix` skill in step `[2/5]`; the step label was generalised from "cc-menu skills" to "skills".

### Documentation

- **`README.md`** — `/pwshfix` feature bullet; Method C skill table now carries a **Platform** column and lists three skills; new section *9. PowerShell Startup Troubleshooting*; new subsection *PowerShell Profile Startup & Prompt*; project tree updated.

## [v2.4.2] — 2026-08-14

### Fixed

- `cc-run`: purge stale `modelOverrides` during the atomic switch.

## [v2.4.1] — 2026-08-13

### Fixed

- `modelOverrides` object schema.
- Non-TTY `--print` launch.

## [v2.4.0] — 2026-08 (macOS feature release; described in the README, not tagged)

### Added

- Health checks before switching, CPA auto-discovery (`cc` with no args), `cc-run` task scheduling, `cc-config`, `cc-test` — macOS now at parity with the Windows/PowerShell version.

## [v2.3.0] — 2026-07-15

### Added

- Health-check before switch; final verification re-pings every assigned model.
- Auth priority (`ANTHROPIC_AUTH_TOKEN` > `ANTHROPIC_API_KEY`).
- Runtime 503 detection with recovery suggestions.

## [v2.2.1] — 2026-07-14

### Fixed

- Final verification phase guarantees all assigned models are healthy.

## [v2.2.0] — 2026-07-14

### Added

- Model selection with a health cache and sequential early-exit probing.

## [v2.1.0] — 2026-07-14

### Added

- CPA auto-discovery, task scheduling, health-checked model assignment.