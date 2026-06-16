<function>
# cc-switch.ps1 — Claude Code Model Switcher for PowerShell
# Dot-source: . .\cc-switch.ps1   or add to $PROFILE
# https://github.com/luyuehm/cc-switch

$script:CC_SETTINGS_PATH = "$env:USERPROFILE\.claude\settings.json"
$script:CC_EXE_PATH = "$env:USERPROFILE\.local\bin\claude.exe"
$script:CC_FALLBACK_EXES = @(
    "$env:LOCALAPPDATA\Programs\claude\claude.exe",
    "$env:APPDATA\npm\claude.cmd"
)

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

    # Launch Claude Code with API key auth (no OAuth)
    $claudeExe = Find-ClaudeExe
    if (-not $claudeExe) { return }

    Write-Host "Launching Claude Code (API key auth, --bare)..." -ForegroundColor Cyan
    Write-Host ""

    $env:ANTHROPIC_API_KEY = $json.env.ANTHROPIC_API_KEY
    $env:ANTHROPIC_BASE_URL = $json.env.ANTHROPIC_BASE_URL
    & $claudeExe --bare
}

function global:cc-pro {
    Write-Host "Switching to claude-opus-4-7..." -ForegroundColor Cyan
    cc claude-opus-4-7
}

function global:cc-fast {
    Write-Host "Switching to deepseek-v4-flash..." -ForegroundColor Cyan
    cc deepseek-v4-flash
}

function global:cc-default {
    Write-Host "Restoring gpt-5.5..." -ForegroundColor Cyan
    cc gpt-5.5
}

function global:cc-status {
    $json = Get-CCSettings
    if (-not $json) { return }

    $current = $json.env.ANTHROPIC_MODEL

    Write-Host ""
    Write-Host "=== Claude Code Model Status ===" -ForegroundColor Cyan
    Write-Host "  Current : $current" -ForegroundColor Green
    Write-Host "  Model   : $($json.model)" -ForegroundColor White
    Write-Host "  Fallback: $($json.fallbackModel -join ', ')" -ForegroundColor Gray
    Write-Host "  Base URL: $($json.env.ANTHROPIC_BASE_URL)" -ForegroundColor Gray
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

    # Show others (ungrouped)
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
    Write-Host "  cc <model>         Switch and launch" -ForegroundColor White
    Write-Host "  cc                 This menu" -ForegroundColor White
    Write-Host "  cc-status          Full model inventory" -ForegroundColor White
    Write-Host ""
    Write-Host "  cc-pro             claude-opus-4-7" -ForegroundColor White
    Write-Host "  cc-fast            deepseek-v4-flash" -ForegroundColor White
    Write-Host "  cc-default         gpt-5.5" -ForegroundColor White
    Write-Host ""
    Write-Host "Current: $current" -ForegroundColor Green
    Write-Host ""
    Write-Host "GPT:        gpt-5.5  gpt-5.4-mini  gpt-5.3-codex" -ForegroundColor Gray
    Write-Host "Claude:     claude-sonnet-4.6  claude-opus-4-7" -ForegroundColor Gray
    Write-Host "DeepSeek:   deepseek-v4-flash  deepseek-v4-flash-free" -ForegroundColor Gray
    Write-Host "Qwen:       qwen3.6-35b-a3b-nvfp4  qwen3.6-plus-free" -ForegroundColor Gray
    Write-Host "Grok:       grok-4.20-auto  grok-4.20-fast" -ForegroundColor Gray
    Write-Host "Moonshot:   moonshotai/kimi-k2.6" -ForegroundColor Gray
    Write-Host "AI/Other:   ai  ai-model  multi-model  fallback" -ForegroundColor Gray
}
