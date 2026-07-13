# cc-switch.ps1 — Claude Code Model Switcher for PowerShell
# Dot-source: . .\cc-switch.ps1   or add to $PROFILE
# https://github.com/luyuehm/cc-switch

$script:CC_SETTINGS_PATH = "$env:USERPROFILE\.claude\settings.json"
$script:CC_EXE_PATH = "$env:USERPROFILE\.local\bin\claude.exe"
$script:CC_ENV_PATH = "$env:USERPROFILE\.claude\cc-switch.env"
$script:CC_FALLBACK_EXES = @(
    "$env:LOCALAPPDATA\Programs\claude\claude.exe",
    "$env:APPDATA\npm\claude.cmd"
)

function Load-CCEnv {
    # Load secrets from cc-switch.env (not committed to git)
    if (Test-Path $script:CC_ENV_PATH) {
        Get-Content $script:CC_ENV_PATH | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\s*([^#][^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

# Load env at script import time
Load-CCEnv

function Find-ClaudeExe {
    if (Test-Path $script:CC_EXE_PATH) { return $script:CC_EXE_PATH }
    foreach ($p in $script:CC_FALLBACK_EXES) {
        if (Test-Path $p) { return $p }
    }
    Write-Host "Error: claude.exe not found. Tried:" -ForegroundColor Red
    ($script:CC_EXE_PATH, $script:CC_FALLBACK_EXES) | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    return $null
}

function Get-CCSettings {
    if (-not (Test-Path $script:CC_SETTINGS_PATH)) {
        Write-Host "Error: settings.json not found at $script:CC_SETTINGS_PATH" -ForegroundColor Red
        return $null
    }
    return Get-Content $script:CC_SETTINGS_PATH -Raw | ConvertFrom-Json
}

function Save-CCSettings($json) {
    $json | ConvertTo-Json -Depth 10 | Set-Content $script:CC_SETTINGS_PATH -Encoding UTF8
}

<#
.SYNOPSIS
    Switch Claude Code model and launch. Or display model inventory.
.DESCRIPTION
    cc <model>   — switch to model, update all config fields, launch Claude Code
    cc           — display current model and shortcuts
    cc-status    — full grouped model inventory
    cc-pro       — shortcut: claude-opus-4-7
    cc-fast      — shortcut: deepseek-v4-flash
    cc-default   — shortcut: gpt-5.5
#>
function global:cc {
    param([string]$Model = "")

    if ([string]::IsNullOrEmpty($Model)) {
        Show-CCMenu
        return
    }

    $json = Get-CCSettings
    if (-not $json) { return }

    if ($json.availableModels -notcontains $Model) {
        Write-Host "Error: '$Model' not in availableModels ($($json.availableModels.Count) total)" -ForegroundColor Red
        return
    }

    $oldModel = $json.env.ANTHROPIC_MODEL

    # Atomic switch — all model refs
    $json.env.ANTHROPIC_MODEL = $Model
    $json.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model
    $json.env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = $Model
    $json.env.ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
    $json.env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = $Model
    $json.env.ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
    $json.env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = $Model
    $json.env.ANTHROPIC_REASONING_MODEL = $Model
    $json.fallbackModel = @($Model)
    $json.model = $Model

    Save-CCSettings $json

    Write-Host "OK: Model switched" -ForegroundColor Green
    Write-Host "  Old: $oldModel" -ForegroundColor Gray
    Write-Host "  New: $Model" -ForegroundColor Green
    Write-Host ""

    # Launch Claude Code with API key from .env or settings.json
    $claudeExe = Find-ClaudeExe
    if (-not $claudeExe) { return }

    # .env values already loaded by Load-CCEnv at script import.
    # If not set, fall back to settings.json values.
    if (-not $env:ANTHROPIC_API_KEY) {
        $env:ANTHROPIC_API_KEY = $json.env.ANTHROPIC_API_KEY
    }
    if (-not $env:ANTHROPIC_BASE_URL) {
        $env:ANTHROPIC_BASE_URL = $json.env.ANTHROPIC_BASE_URL
    }

    Write-Host "Launching Claude Code (API key auth, --bare)..." -ForegroundColor Cyan
    Write-Host ""

    & $claudeExe --bare
}

function global:cc-pro {
    Write-Host "Switching to claude-opus-4-7..." -ForegroundColor Cyan
    cc claude-opus-4-7
}

function global:cc-run {
    <#
    .SYNOPSIS
        Launch Claude Code with a task-appropriate model. Maps task types to optimal models.
    .PARAMETER Task
        Task type or model name. Built-in types:
          code    → claude-sonnet-4.6    (best for coding)
          quick   → deepseek-v4-flash    (fast/cheap for simple tasks)
          reason  → gpt-5.6-sol          (strong reasoning/analysis)
          image   → gpt-image-2          (image generation)
          default → deepseek-v4-flash    (general purpose)
        Or pass any model name directly (e.g., "qwen3.6-max-preview").
    .EXAMPLE
        cc-run code           # start with coding-optimized model
        cc-run quick          # start with fast model
        cc-run reason         # start with strong reasoning model
        cc-run gpt-5.5        # start with specific model
    #>
    param([string]$Task = "default")

    $modelMap = @{
        code    = "gpt-5.5"             # Best for coding (verified)
        quick   = "deepseek-v4-flash"   # Fast/cheap (verified)
        reason  = "qwen3.6-plus"        # Strong reasoning (verified)
        image   = "gpt-5.5"             # Image gen not available, fallback
        default = "deepseek-v4-flash"   # General purpose (verified)
    }

    if ($modelMap.ContainsKey($Task)) {
        $model = $modelMap[$Task]
        Write-Host "[cc-run] Task '$Task' → model: $model" -ForegroundColor Cyan
    } else {
        $model = $Task
        Write-Host "[cc-run] Direct model: $model" -ForegroundColor Cyan
    }

    cc $model
}

function global:cc-fast {
    Write-Host "Switching to deepseek-v4-flash..." -ForegroundColor Cyan
    cc deepseek-v4-flash
}

function global:cc-default {
    Write-Host "Restoring gpt-5.5..." -ForegroundColor Cyan
    cc gpt-5.5
}

function global:cc-sync {
    <#
    .SYNOPSIS
        Fetch available models from CPA endpoint and sync to local availableModels.
    .PARAMETER List
        Show full model list from CPA (no sync).
    .PARAMETER Force
        Auto-add new models without confirmation.
    .PARAMETER Remove
        Remove models that no longer exist on CPA from local list.
    #>
    param(
        [switch]$List,
        [switch]$Force,
        [switch]$Remove
    )

    # Determine CPA models URL
    $cpaUrl = if ($env:CPA_MODELS_URL) {
        $env:CPA_MODELS_URL
    } else {
        $baseUrl = if ($env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL } else {
            $json = Get-CCSettings
            if ($json) { $json.env.ANTHROPIC_BASE_URL } else { "" }
        }
        if ($baseUrl) { "$baseUrl/v1/models" } else { "" }
    }

    $apiKey = if ($env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY } else {
        $json = Get-CCSettings
        if ($json -and $json.env.ANTHROPIC_API_KEY) { $json.env.ANTHROPIC_API_KEY } else { "" }
    }

    if (-not $cpaUrl -or -not $apiKey) {
        Write-Host "Error: CPA_MODELS_URL or API key not configured." -ForegroundColor Red
        Write-Host "  Set CPA_MODELS_URL and ANTHROPIC_API_KEY in ~\.claude\cc-switch.env" -ForegroundColor Yellow
        return
    }

    Write-Host "Fetching models from CPA..." -ForegroundColor Cyan
    Write-Host "  $cpaUrl" -ForegroundColor Gray

    try {
        $response = Invoke-RestMethod -Uri $cpaUrl -Headers @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type" = "application/json"
        } -TimeoutSec 15 -ErrorAction Stop

        $cpaModels = if ($response.data) {
            $response.data | ForEach-Object { $_.id } | Where-Object { $_ }
        } elseif ($response -is [array]) {
            $response | ForEach-Object { $_.id } | Where-Object { $_ }
        } else {
            Write-Host "Error: unexpected CPA response format." -ForegroundColor Red
            return
        }

        if ($cpaModels.Count -eq 0) {
            Write-Host "No models returned from CPA." -ForegroundColor Red
            return
        }

        Write-Host "  Got $($cpaModels.Count) models from CPA" -ForegroundColor Green
    } catch {
        Write-Host "Error fetching CPA models: $_" -ForegroundColor Red
        return
    }

    # -List mode: just show the full model list, no sync
    if ($List) {
        Write-Host ""
        Write-Host "=== CPA Models ($($cpaModels.Count)) ===" -ForegroundColor Cyan
        $cpaModels | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "--- $(cpaModels.Count) models ---" -ForegroundColor Gray
        return
    }

    $json = Get-CCSettings
    if (-not $json) { return }

    $local = $json.availableModels
    $newModels = @($cpaModels | Where-Object { $_ -notin $local })
    $goneModels = @($local | Where-Object { $_ -notin $cpaModels })

    Write-Host ""
    Write-Host "=== CPA Sync Report ===" -ForegroundColor Cyan
    Write-Host "  CPA total : $($cpaModels.Count)" -ForegroundColor White
    Write-Host "  Local     : $($local.Count)" -ForegroundColor White
    if ($newModels.Count -gt 0) {
        Write-Host "  New       : +$($newModels.Count) (not yet in local)" -ForegroundColor Green
    }
    if ($goneModels.Count -gt 0) {
        Write-Host "  Gone      : -$($goneModels.Count) (removed from CPA)" -ForegroundColor Yellow
    }

    # Always show CPA model list with category grouping
    Write-Host ""
    Write-Host "=== CPA Model List ===" -ForegroundColor Cyan

    # Detect prefix categories
    $categories = $cpaModels | Sort-Object | Group-Object -Property {
        if ($_ -imatch "^(gpt|o\d)") { "OpenAI" }
        elseif ($_ -imatch "^claude|^sonnet|^haiku") { "Anthropic" }
        elseif ($_ -imatch "^deepseek") { "DeepSeek" }
        elseif ($_ -imatch "^qwen") { "Qwen/Alibaba" }
        elseif ($_ -imatch "^grok") { "Grok/xAI" }
        elseif ($_ -imatch "^llama") { "Meta/Llama" }
        elseif ($_ -imatch "^mistral|^mixtral") { "Mistral" }
        elseif ($_ -imatch "^gemin") { "Google/Gemini" }
        elseif ($_ -imatch "^kimi|^moonshot") { "Moonshot/Kimi" }
        elseif ($_ -imatch "step") { "Stepfun" }
        else { "Other" }
    }

    $categories | Sort-Object Name | ForEach-Object {
        Write-Host "  [$($_.Name)]" -ForegroundColor Magenta
        $_.Group | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }

    Write-Host ""
    Write-Host "Press Enter to continue, or type 'q' to cancel sync" -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    if ($choice -eq "q") {
        Write-Host "Sync cancelled." -ForegroundColor Gray
        return
    }

    if ($newModels.Count -gt 0) {
        Write-Host ""
        Write-Host "New models available:" -ForegroundColor Green
        $newModels | Sort-Object | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }

        if ($Force) {
            $add = $true
        } else {
            Write-Host ""
            Write-Host "Add these to local list? [Y/n] " -ForegroundColor Yellow -NoNewline
            $choice = Read-Host
            $add = ($choice -eq "" -or $choice -eq "y" -or $choice -eq "Y")
        }

        if ($add) {
            $merged = @($local) + @($newModels) | Sort-Object -Unique
            $json.availableModels = $merged
            Save-CCSettings $json
            Write-Host "Updated: $($local.Count) -> $($merged.Count) models" -ForegroundColor Green
        } else {
            Write-Host "Skipped. Use 'cc-sync -Force' to auto-add." -ForegroundColor Gray
        }
    }

    if ($goneModels.Count -gt 0) {
        Write-Host ""
        Write-Host "Models removed from CPA (still in local):" -ForegroundColor Yellow
        $goneModels | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

        if ($Remove) {
            $cleaned = @($local | Where-Object { $_ -in $cpaModels })
            $json.availableModels = $cleaned | Sort-Object -Unique
            Save-CCSettings $json
            Write-Host "Cleaned: $($local.Count) -> $($cleaned.Count) models" -ForegroundColor Green
        } else {
            Write-Host "To remove: cc-sync -Remove" -ForegroundColor Gray
        }
    }

    if ($newModels.Count -eq 0 -and $goneModels.Count -eq 0) {
        Write-Host "  Status: fully in sync" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Tip: cc-sync -List     — show full model list only" -ForegroundColor Gray
    Write-Host "Tip: cc-sync -Force    — auto-add new models" -ForegroundColor Gray
    Write-Host "Tip: cc-sync -Remove   — remove obsolete models" -ForegroundColor Gray
}

function global:cc-test {
    <#
    .SYNOPSIS
        Test all available models for quota/availability by sending a short ping.
        Reports healthy vs unhealthy models and optionally removes dead ones.
    .PARAMETER RemoveDead
        Remove models that fail the test from availableModels.
    .PARAMETER Timeout
        Seconds to wait per model test (default 15).
    .PARAMETER Parallel
        Number of parallel tests (default 5).
    #>
    param(
        [switch]$RemoveDead,
        [int]$Timeout = 15,
        [int]$Parallel = 5
    )

    $json = Get-CCSettings
    if (-not $json -or -not $json.availableModels -or $json.availableModels.Count -eq 0) {
        Write-Host "Error: no availableModels in settings.json" -ForegroundColor Red
        return
    }

    $baseUrl = if ($env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL } else { $json.env.ANTHROPIC_BASE_URL }
    $apiKey = if ($env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY } else { $json.env.ANTHROPIC_API_KEY }

    if (-not $baseUrl -or -not $apiKey) {
        Write-Host "Error: ANTHROPIC_BASE_URL or API key not configured." -ForegroundColor Red
        return
    }

    $headers = @{
        "Content-Type" = "application/json"
        "x-api-key" = $apiKey
        "anthropic-version" = "2023-06-01"
    }
    # For CPA endpoints, use Bearer auth
    $headers["Authorization"] = "Bearer $apiKey"

    $models = $json.availableModels
    $total = $models.Count
    $current = 0

    Write-Host ""
    Write-Host "=== Model Health Test ===" -ForegroundColor Cyan
    Write-Host "  Models : $total"
    Write-Host "  Endpoint: $baseUrl"
    Write-Host "  Timeout: ${Timeout}s per model"
    Write-Host "  Parallel: $Parallel"
    Write-Host ""

    $results = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()

    $models | ForEach-Object -Parallel {
        $modelName = $_
        $baseUrl = $using:baseUrl
        $headers = $using:headers
        $timeout = $using:Timeout
        $results = $using:results

        $body = @{
            model    = $modelName
            messages = @(@{ role = "user"; content = "ping" })
            max_tokens = 5
        } | ConvertTo-Json

        try {
            $response = Invoke-RestMethod -Uri "$baseUrl/v1/messages" `
                -Method Post `
                -Headers $headers `
                -Body $body `
                -ContentType "application/json" `
                -TimeoutSec $timeout `
                -ErrorAction Stop

            $results.Add(@{ model = $modelName; status = "healthy" })
            Write-Host "  [OK]  $modelName" -ForegroundColor Green
        } catch {
            $statusCode = 0
            $errorMsg = $_.Exception.Message
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -in (429, 403, 402) -or $errorMsg -match "quota|insufficient|rate.limit|额度不足|超出配额|余额不足") {
                $results.Add(@{ model = $modelName; status = "quota" })
                Write-Host "  [QUOTA]  $modelName (HTTP $statusCode)" -ForegroundColor Yellow
            } else {
                $results.Add(@{ model = $modelName; status = "failed" })
                Write-Host "  [FAIL]  $modelName (HTTP $statusCode)" -ForegroundColor Red
            }
        }
    } -ThrottleLimit $Parallel

    $healthy   = @($results | Where-Object { $_.status -eq "healthy" } | ForEach-Object { $_.model })
    $quotaErrors = @($results | Where-Object { $_.status -eq "quota" } | ForEach-Object { $_.model })
    $unhealthy = @($results | Where-Object { $_.status -eq "failed" } | ForEach-Object { $_.model })

    Write-Host ""
    Write-Host "=== Test Results ===" -ForegroundColor Cyan
    Write-Host "  Healthy   : $($healthy.Count) / $total" -ForegroundColor Green
    Write-Host "  Quota-Low : $($quotaErrors.Count) / $total" -ForegroundColor Yellow
    Write-Host "  Failed    : $($unhealthy.Count) / $total" -ForegroundColor Red

    if ($healthy.Count -gt 0) {
        Write-Host ""
        Write-Host "Healthy models:" -ForegroundColor Green
        $healthy | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
    if ($quotaErrors.Count -gt 0) {
        Write-Host ""
        Write-Host "Quota exhausted (may recover later):" -ForegroundColor Yellow
        $quotaErrors | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    if ($unhealthy.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed (likely unavailable):" -ForegroundColor Red
        $unhealthy | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }

    if ($RemoveDead -and $unhealthy.Count -gt 0) {
        Write-Host ""
        Write-Host "Removing $($unhealthy.Count) failed models from availableModels..." -ForegroundColor Yellow
        $json.availableModels = @($json.availableModels | Where-Object { $_ -notin $unhealthy })
        Save-CCSettings $json
        Write-Host "[OK]  Removed $($unhealthy.Count) models. Remaining: $($json.availableModels.Count)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Tip: cc-test -RemoveDead   — remove failed models from list" -ForegroundColor Gray
    Write-Host "Tip: cc-test -Timeout 30   — increase timeout for slow models" -ForegroundColor Gray
}

function global:cc-audit {
    <#
    .SYNOPSIS
        Audit current Claude Code skill visibility and custom commands.
    #>
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  Claude Code Menu Audit Report" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host ""

    # Custom commands
    Write-Host "== Custom Slash Commands (commands/) ====" -ForegroundColor White
    $commandsDir = "$env:USERPROFILE\.claude\commands"
    if (Test-Path $commandsDir) {
        $cmds = Get-ChildItem "$commandsDir\*.md" -ErrorAction SilentlyContinue | Sort-Object Name
        if ($cmds.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor Gray
        } else {
            foreach ($f in $cmds) {
                $desc = ""
                $lines = Get-Content $f.FullName -TotalCount 10
                foreach ($line in $lines) {
                    if ($line -match "^description:\s*(.+)") {
                        $desc = $matches[1].Trim('"')
                        break
                    }
                }
                Write-Host "  [OK]  /$($f.BaseName) — $($desc)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  (commands dir not found)" -ForegroundColor Gray
    }
    Write-Host ""

    # Hidden skills
    Write-Host "== Hidden Skills (skillOverrides) ====" -ForegroundColor White
    $json = Get-CCSettings
    if ($json -and $json.skillOverrides) {
        if ($json.skillOverrides.Count -eq 0) {
            Write-Host "  (none)" -ForegroundColor Gray
        } else {
            foreach ($kvp in $json.skillOverrides.GetEnumerator()) {
                Write-Host "  [HIDDEN]  $($kvp.Key) → $($kvp.Value)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  (none)" -ForegroundColor Gray
    }
    Write-Host ""

    # Plugin skills
    Write-Host "== Plugin Skills (enabledPlugins) ====" -ForegroundColor White
    if ($json -and $json.enabledPlugins) {
        $ov = $json.skillOverrides
        foreach ($plugin in $json.enabledPlugins.PSObject.Properties) {
            if ($plugin.Value) {
                $hidden = ($ov.PSObject.Properties.Name | Where-Object {
                    $_ -like "$($plugin.Name):*" -and $ov.$_ -eq "off"
                }).Count
                $status = if ($hidden -gt 0) { "$hidden hidden" } else { "all visible" }
                Write-Host "  [PACKAGE]  $($plugin.Name): $status" -ForegroundColor Cyan
            }
        }
    } else {
        Write-Host "  (no plugins configured)" -ForegroundColor Gray
    }
    Write-Host ""

    $cmdCount = (Get-ChildItem "$commandsDir\*.md" -ErrorAction SilentlyContinue).Count
    Write-Host "Total: $cmdCount custom commands" -ForegroundColor Cyan
}

function global:cc-hide {
    <#
    .SYNOPSIS
        Hide a skill or entire plugin from Claude Code menu.
    .PARAMETER Name
        Skill name or plugin wildcard (e.g., "docx" or "document-skills:*")
    #>
    param([string]$Name)

    if (-not $Name) {
        Write-Host "Usage: cc-hide <skill-name|plugin:*>" -ForegroundColor Red
        return
    }

    $json = Get-CCSettings
    if (-not $json) {
        Write-Host "Error: settings.json not found." -ForegroundColor Red
        return
    }

    if (-not $json.skillOverrides) {
        $json.skillOverrides = [PSCustomObject]@{}
    }

    if ($Name -like "*:*" -and $Name.EndsWith("*")) {
        $plugin = $Name.Split(":")[0]
        $propertyName = $plugin + ":*"
        $json.skillOverrides | Add-Member -NotePropertyName $propertyName -NotePropertyValue "off" -Force
        Write-Host "[HIDDEN]  Hiding plugin: $plugin (all skills)" -ForegroundColor Yellow
    } else {
        $json.skillOverrides | Add-Member -NotePropertyName $Name -NotePropertyValue "off" -Force
        Write-Host "[HIDDEN]  Hiding skill: $Name" -ForegroundColor Yellow
    }

    Save-CCSettings $json
}

function global:cc-show {
    <#
    .SYNOPSIS
        Restore visibility of a hidden skill or plugin.
    .PARAMETER Name
        Skill name or plugin wildcard (e.g., "docx" or "document-skills:*")
    #>
    param([string]$Name)

    if (-not $Name) {
        Write-Host "Usage: cc-show <skill-name|plugin:*>" -ForegroundColor Red
        return
    }

    $json = Get-CCSettings
    if (-not $json -or -not $json.skillOverrides) {
        Write-Host "[!]   No skillOverrides configured." -ForegroundColor Yellow
        return
    }

    if ($Name -like "*:*" -and $Name.EndsWith("*")) {
        $plugin = $Name.Split(":")[0]
        $keys = $json.skillOverrides.PSObject.Properties.Name | Where-Object { $_ -like ($plugin + ":*") }
        $count = $keys.Count
        foreach ($k in $keys) {
            $json.skillOverrides.PSObject.Properties.Remove($k) | Out-Null
        }
        Save-CCSettings $json
        Write-Host "[OK]  Restored plugin: $plugin ($count items)" -ForegroundColor Green
    } else {
        if ($json.skillOverrides.PSObject.Properties.Name -contains $Name) {
            $json.skillOverrides.PSObject.Properties.Remove($Name) | Out-Null
            Save-CCSettings $json
            Write-Host "[OK]  Restored: $Name" -ForegroundColor Green
        } else {
            Write-Host "[!]   $Name is not hidden." -ForegroundColor Yellow
        }
    }
}

function global:cc-profile {
    <#
    .SYNOPSIS
        Switch between preset skill visibility profiles.
    .PARAMETER Name
        Profile name: default, minimal, dev, custom
    #>
    param(
        [ValidateSet("default", "minimal", "dev", "custom")]
        [string]$Name = "default"
    )

    $json = Get-CCSettings
    if (-not $json) {
        Write-Host "Error: settings.json not found." -ForegroundColor Red
        return
    }

    if ($Name -eq "default") {
        $json.PSObject.Properties.Remove("skillOverrides")
        Save-CCSettings $json
        Write-Host "[OK]  Switched to 'default' profile: all skills visible" -ForegroundColor Green
    }
    elseif ($Name -eq "minimal") {
        $json.skillOverrides = [PSCustomObject]@{
            "document-skills:*" = "off"
            "example-skills:*" = "off"
            "financial-analysis:*" = "user-invocable-only"
            "pitch-agent:*" = "user-invocable-only"
            "claude-api:*" = "name-only"
        }
        Save-CCSettings $json
        Write-Host "[OK]  Switched to 'minimal' profile: hidden docs/examples, financial/pitch menu-only" -ForegroundColor Green
    }
    elseif ($Name -eq "dev") {
        $json.skillOverrides = [PSCustomObject]@{
            "document-skills:*" = "off"
            "example-skills:*" = "off"
            "financial-analysis:*" = "off"
            "pitch-agent:*" = "off"
            "claude-api:claude-api" = "user-invocable-only"
        }
        Save-CCSettings $json
        Write-Host "[OK]  Switched to 'dev' profile: dev skills only" -ForegroundColor Green
    }
    elseif ($Name -eq "custom") {
        Write-Host "[NOTE]  Custom profile: edit ~/.claude/settings.json skillOverrides manually" -ForegroundColor Cyan
    }
}

function global:cc-commands {
    <#
    .SYNOPSIS
        List or manage custom slash commands.
    .PARAMETER Action
        Action: list, create, remove
    .PARAMETER Name
        Command name (for create/remove)
    .PARAMETER Description
        Command description (for create)
    #>
    param(
        [ValidateSet("list", "create", "remove")]
        [string]$Action = "list",
        [string]$Name,
        [string]$Description
    )

    $commandsDir = "$env:USERPROFILE\.claude\commands"

    if ($Action -eq "list") {
        Write-Host "[LIST]  Custom Slash Commands:" -ForegroundColor Cyan
        if (Test-Path $commandsDir) {
            $cmds = Get-ChildItem "$commandsDir\*.md" -ErrorAction SilentlyContinue | Sort-Object Name
            if ($cmds.Count -eq 0) {
                Write-Host "  (none)" -ForegroundColor Gray
            } else {
                foreach ($f in $cmds) {
                    $desc = ""
                    $lines = Get-Content $f.FullName -TotalCount 10
                    foreach ($line in $lines) {
                        if ($line -match "^description:\s*(.+)") {
                            $desc = $matches[1].Trim('"')
                            break
                        }
                    }
                    Write-Host "  /$($f.BaseName) — $($desc)" -ForegroundColor White
                }
            }
        } else {
            Write-Host "  (commands dir not found)" -ForegroundColor Gray
        }
    }
    elseif ($Action -eq "create") {
        if (-not $Name) {
            Write-Host "Usage: cc-commands create <name> <description>" -ForegroundColor Red
            return
        }
        $commandsDir = "$env:USERPROFILE\.claude\commands"
        New-Item -ItemType Directory -Force -Path $commandsDir | Out-Null
        $filepath = Join-Path $commandsDir "$Name.md"
        if (Test-Path $filepath) {
            Write-Host "[!]   /$Name already exists" -ForegroundColor Yellow
            return
        }
        $content = "---`ndescription: $Description`n---`n`n"
        Set-Content -Path $filepath -Value $content
        Write-Host "[OK]  Created /$Name → $filepath" -ForegroundColor Green
    }
    elseif ($Action -eq "remove") {
        if (-not $Name) {
            Write-Host "Usage: cc-commands remove <name>" -ForegroundColor Red
            return
        }
        $filepath = Join-Path $commandsDir "$Name.md"
        if (Test-Path $filepath) {
            Remove-Item $filepath -Force
            Write-Host "[OK]  Deleted /$Name" -ForegroundColor Green
        } else {
            Write-Host "[!]   /$Name not found" -ForegroundColor Yellow
        }
    }
}

function global:cc-theme {
    [CmdletBinding(DefaultParameterSetName='list')]
    param(
        [Parameter(Position=0, ParameterSetName='set')]
        [string]$Name,

        [Parameter(ParameterSetName='list')]
        [switch]$List
    )

    $themeDir = "C:\tools\oh-my-posh\themes"
    $ohMyPoshExe = "C:\tools\oh-my-posh.exe"

    if (-not (Test-Path $themeDir)) {
        Write-Host "[!]   Oh My Posh not installed." -ForegroundColor Yellow
        Write-Host "  Install: irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex" -ForegroundColor Gray
        Write-Host "  Say Y when asked about pwsh enhancements." -ForegroundColor Gray
        return
    }

    $themes = Get-ChildItem "$themeDir\*.omp.json" | Sort-Object Name

    if ($Name) {
        $themeFile = Join-Path $themeDir "$Name.json"
        if (-not (Test-Path $themeFile)) {
            $themeFile = Join-Path $themeDir "$Name.omp.json"
        }
        if (-not (Test-Path $themeFile)) {
            Write-Host "[!]   Theme '$Name' not found." -ForegroundColor Yellow
            Write-Host "  Themes available:" -ForegroundColor Gray
            $themes | ForEach-Object { Write-Host "    $($_.BaseName)" -ForegroundColor Gray }
            return
        }
        & $ohMyPoshExe init pwsh --config $themeFile.FullName | Invoke-Expression
        Write-Host "[OK]  Switched to theme: $($themeFile.BaseName)" -ForegroundColor Green
        Write-Host "  To make permanent, edit `$PROFILE and change the theme path." -ForegroundColor Gray
        return
    }

    # List themes with popular markers
    Write-Host ""
    Write-Host "=== Oh My Posh Themes ($($themes.Count)) ===" -ForegroundColor Cyan
    Write-Host ""

    $popular = @("powerlevel10k_rainbow", "powerlevel10k_classic", "montys", "catppuccin", "star", "tokyonight_storm", "gruvbox", "dracula")

    $themes | ForEach-Object {
        $marker = if ($_.BaseName -in $popular) { " =>" } else { "   " }
        Write-Host "  $marker $($_.BaseName)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  cc-theme <name>    Switch to theme (live preview)" -ForegroundColor White
    Write-Host "  cc-theme           Show this list" -ForegroundColor White
    Write-Host "  cc-theme montys    Example: switch to montys" -ForegroundColor White
    Write-Host ""
    Write-Host "To make permanent, edit `$PROFILE and update `$poshTheme path." -ForegroundColor Gray
    Write-Host "Popular themes marked with =>" -ForegroundColor Gray
}

function global:cc-status {
    $json = Get-CCSettings
    if (-not $json) { return }

    $current = $json.env.ANTHROPIC_MODEL
    $baseUrl = if ($env:ANTHROPIC_BASE_URL) { $env:ANTHROPIC_BASE_URL } else { $json.env.ANTHROPIC_BASE_URL }

    Write-Host ""
    Write-Host "=== Claude Code Model Status ===" -ForegroundColor Cyan
    Write-Host "  Current : $current" -ForegroundColor Green
    Write-Host "  Model   : $($json.model)" -ForegroundColor White
    Write-Host "  Fallback: $($json.fallbackModel -join ', ')" -ForegroundColor Gray
    Write-Host "  Base URL: $baseUrl" -ForegroundColor Gray
    Write-Host "  Available: $($json.availableModels.Count) models" -ForegroundColor Gray
    Write-Host ""

    $groups = @{
        "GPT"      = @($json.availableModels | Where-Object { $_ -like "gpt-*" })
        "Claude"   = @($json.availableModels | Where-Object { $_ -like "*claude*" })
        "DeepSeek" = @($json.availableModels | Where-Object { $_ -like "*deepseek*" })
        "Qwen"     = @($json.availableModels | Where-Object { $_ -like "*qwen*" })
        "Grok"     = @($json.availableModels | Where-Object { $_ -like "grok*" })
        "Moonshot" = @($json.availableModels | Where-Object { $_ -like "moonshotai*" })
        "StepFun"  = @($json.availableModels | Where-Object { $_ -like "stepfun*" })
    }

    foreach ($g in $groups.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending) {
        if ($g.Value.Count -gt 0) {
            Write-Host "$($g.Key) ($($g.Value.Count))" -ForegroundColor Yellow
            foreach ($m in ($g.Value | Sort-Object)) {
                $marker = if ($m -eq $current) { " <-- current" } else { "" }
                Write-Host "  $m$marker" -ForegroundColor White
            }
            Write-Host ""
        }
    }

    $grouped = $groups.Values | ForEach-Object { $_ } | Select-Object -Unique
    $others = @($json.availableModels | Where-Object { $_ -notin $grouped })
    if ($others.Count -gt 0) {
        Write-Host "Other ($($others.Count))" -ForegroundColor Yellow
        foreach ($m in ($others | Sort-Object)) {
            $marker = if ($m -eq $current) { " <-- current" } else { "" }
            Write-Host "  $m$marker" -ForegroundColor White
        }
    }
}

function global:Get-CCModel {
    $json = Get-CCSettings
    if ($json) { return $json.env.ANTHROPIC_MODEL }
    return $null
}

function Show-CCMenu {
    $current = Get-CCModel
    Write-Host ""
    Write-Host "=== Claude Code Model Switcher ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  cc-run <task>      Task-smart launch (code|quick|reason|image)" -ForegroundColor White
    Write-Host "    cc-run code      Coding (gpt-5.5)" -ForegroundColor Gray
    Write-Host "    cc-run quick     Fast (deepseek-v4-flash)" -ForegroundColor Gray
    Write-Host "    cc-run reason    Deep analysis (qwen3.6-plus)" -ForegroundColor Gray
    Write-Host "    cc-run image     Image gen (gpt-5.5 fallback)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  cc <model>         Switch and launch" -ForegroundColor White
    Write-Host "  cc                 This menu" -ForegroundColor White
    Write-Host "  cc-status          Full model inventory" -ForegroundColor White
    Write-Host "  cc-sync            Sync models from CPA" -ForegroundColor White
    Write-Host "    cc-sync -List    Show full CPA model list" -ForegroundColor Gray
    Write-Host "    cc-sync -Force   Auto-add new models" -ForegroundColor Gray
    Write-Host "    cc-sync -Remove  Remove obsolete models" -ForegroundColor Gray
    Write-Host "  cc-test            Test all models for quota/health" -ForegroundColor White
    Write-Host "    cc-test -RemoveDead  Auto-remove failed models" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  cc-audit           Audit skill visibility" -ForegroundColor White
    Write-Host "  cc-hide <skill>    Hide skill or plugin" -ForegroundColor White
    Write-Host "  cc-show <skill>    Restore hidden skill" -ForegroundColor White
    Write-Host "  cc-profile <name>  Switch preset (default|minimal|dev)" -ForegroundColor White
    Write-Host "  cc-commands        List/manage custom commands" -ForegroundColor White
    Write-Host "  cc-theme           List/switch Oh My Posh theme" -ForegroundColor White
    Write-Host ""
    Write-Host "  cc-pro             claude-opus-4-7" -ForegroundColor White
    Write-Host "  cc-fast            deepseek-v4-flash" -ForegroundColor White
    Write-Host "  cc-default         gpt-5.5" -ForegroundColor White
    Write-Host ""
    Write-Host "Current: $current" -ForegroundColor Green
    Write-Host ""

    # Dynamic model list from availableModels
    $json = Get-CCSettings
    if ($json -and $json.availableModels -and $json.availableModels.Count -gt 0) {
        $cats = @{}
        $json.availableModels | ForEach-Object {
            $cat = if ($_ -imatch "^(gpt|o\d)") { "GPT" }
            elseif ($_ -imatch "^claude|^sonnet|^haiku") { "Claude" }
            elseif ($_ -imatch "^deepseek") { "DeepSeek" }
            elseif ($_ -imatch "^qwen") { "Qwen" }
            elseif ($_ -imatch "^grok") { "Grok" }
            elseif ($_ -imatch "^kimi|^moonshot") { "Moonshot" }
            elseif ($_ -imatch "^llama") { "Llama" }
            elseif ($_ -imatch "^mistral|^mixtral") { "Mistral" }
            elseif ($_ -imatch "^gemin") { "Gemini" }
            elseif ($_ -imatch "step") { "Stepfun" }
            else { "Other" }
            if (-not $cats[$cat]) { $cats[$cat] = @() }
            $cats[$cat] += $_
        }
        $cats.Keys | Sort-Object @{Expression={
            switch ($_) {
                "GPT" { 1 }; "Claude" { 2 }; "DeepSeek" { 3 }; "Grok" { 4 }
                "Qwen" { 5 }; "Gemini" { 6 }; "Moonshot" { 7 }; "Llama" { 8 }
                "Mistral" { 9 }; "Stepfun" { 10 }; default { 99 }
            }
        }} | ForEach-Object {
            $models = $cats[$_] -join "  "
            Write-Host "$($_):`t$models" -ForegroundColor Gray
        }
    }
}
