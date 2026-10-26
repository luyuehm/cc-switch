# Changelog

All notable changes to cc-switch. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each version maps to a git tag.

The repo release version lives in [`VERSION`](VERSION) and is bumped at release time to match the new tag. See **Versioning** in the README for how that relates to each platform's *feature set* label.

## [Unreleased]

### Added

- **Configurable fallback CPA endpoints** — `CPA_FALLBACK_URLS` (both scripts) and `CPA_FALLBACK_API_KEY` (per-entry `url|key` also works) let read-only commands survive a dead primary endpoint. `Resolve-CPAEndpoints` / `__cc_resolve_fallbacks` normalize `http://host`, `http://host/v1` and `http://host/v1/models` to the same base + models URL pair, and `Invoke-CCModelsRequest` / `__cc_fetch_cpa_models` walk the list. Failover happens on transport failure, timeout and 5xx only — a 4xx is a real answer and is reported rather than masked. `cc-sync` and `cc-test` print which endpoint answered; `cc <model>` still launches against `ANTHROPIC_BASE_URL` unchanged.
- **`VERSION`** — single source of truth for the repo release version. Both installers read it and print it in their banner, falling back to an embedded literal when run outside a checkout.
- **`tests/ric-1851-regression.sh`** — macOS regression matrix covering the `a-` ID, settings-persistence and endpoint-resolution fixes below. Runs against a throwaway `HOME` and a local mock of the CPA `/v1/models` endpoint, so it needs no network and never touches the real `~/.claude/settings.json`. 11 checks; the endpoint-resolution checks fail against the previous script.

### Changed

- **`install.sh` / `install.ps1`** — banners now show the repo release version instead of a hardcoded string. `install.sh` previously printed `v2.4.0`, which was the macOS *feature set* and drifted from the repo release.
- **`tests/ric-1851-regression.sh`** — expanded to 11 checks. Two new cases cover this release's bugs and both fail against the pre-fix script: `cc-sync` with `CC_SWITCH_SKIP_ENV=1` reading credentials from `cc-switch.env`, and a credential-free `__cc_resolve_endpoint` returning exactly `|` under zsh (no stray variable dumps).

### Fixed

- **`cc-sync` / `cc-test` (PowerShell) — CPA requests no longer ride a stalling Windows system proxy.** `Invoke-RestMethod` silently honours the WinINET system proxy (Clash / V2Ray in "system proxy" mode), which is tuned for browser traffic and would stall or half-close the chunked ~27 KB `/v1/models` body. Users saw `Error fetching CPA models: Received an unexpected EOF or 0 bytes from the transport stream.` or a bare timeout, even though `curl` reached the same endpoint in milliseconds. All CPA calls now go through a new `Invoke-CCHttp` helper that tries **direct first** and falls back to the system proxy only on a transport-layer failure; a real HTTP status (401/404/5xx) is never retried through the proxy. `CC_PROXY=<url>` forces a proxy and `CC_PROXY=none|off|direct|no` disables proxying entirely; `cc-test`'s parallel block follows the same policy.
- **`cc-sync` — credentials in `cc-switch.env` are found even when startup export is suppressed.** `~/.zshrc` commonly exports `CC_SWITCH_SKIP_ENV=1` before sourcing `cc-switch.sh`, so `__cc_load_env` is a no-op and nothing from `cc-switch.env` is in the environment. `cc-sync` never reloaded it, and `__cc_resolve_endpoint` only fell back to `~/.openclaw/.env`/`settings.json` — so a correctly configured `cc-switch.env` still produced `Error: CPA_MODELS_URL or API key not configured`. The resolver now reads `CPA_MODELS_URL` / `CLAUDE_CODE_BASE_URL` / `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` / `CPA_API_KEY` straight from `$CC_ENV_PATH` via `__cc_env_file_get` (without exporting them), and the error text now lists every source it tried.
- **`cc-switch.sh` — zsh 5.9 printed stray variable dumps into machine-readable output.** A bare `local name` that re-declares an existing local in the same function prints `name=value` to stdout under zsh. In `__cc_resolve_endpoint` this emitted the whole `settings.json` into the `url|key` result, so with missing credentials the settings JSON was used as the curl URL; `__cc_auto_assign` had the same pattern. Both now declare each local exactly once.
- **`cc-switch.sh` — `a-`-prefixed models are first-class IDs.** `a-deepseek-flash` and `deepseek-flash` are now fetched, stored, selected, health-checked and removed as distinct entries. Previously a prefix-stripping/alias-normalising pass could collapse the two, so syncing a CPA that serves both could drop or overwrite one of them. Removal matches the raw ID exactly, so `--remove --id=deepseek-flash` leaves `a-deepseek-flash` alone.
- **`cc-switch.sh` — `CC_SETTINGS_PATH` is passed to the save helper.** It is a plain shell variable, never exported, so the child Python could not see it in `os.environ` and died with `KeyError: 'CC_SETTINGS_PATH'` — which callers ignored. Assigning a custom path (or letting `~/.zshrc` source the script, where nothing is exported) now works.
- **`cc-switch.sh` — settings saves are atomic and failures are no longer reported as success.** The helper writes to a temp file and `os.replace`s it, so an interrupted write cannot truncate the live settings file. Every call site now checks the result and returns non-zero, so a failed save no longer prints `[OK] Updated` / `Done` while the file is unchanged.
- **`cc-switch.sh` — an unparseable settings file is reported, not overwritten.** A corrupt JSON file used to be silently replaced with `{"availableModels":[],"env":{}}`, deleting every configured model; it is now refused with an error.
- **`cc-switch.sh` — `cc-show` strips its trailing marker portably.** `json.dump` emits no trailing newline, so the marker was glued to the closing brace (`}REMOVED`) and never matched; and `head -n -1` is a GNU extension that fails on macOS BSD `head`, making the restore a silent no-op. The marker is now newline-terminated and removed with `sed '$d'`.

### Documentation

- **`README.md`** — new "Fallback CPA endpoints" subsection (list format, per-entry keys, which commands walk the list) and the two new variables in the Configuration env block.
- **`README.md`** — versioning note explaining repo release vs per-platform feature set; `VERSION` added to the project tree.
- **`cc-switch.sh` / `cc-switch.ps1`** — header comments now distinguish the repo release version from the platform feature-set label.

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