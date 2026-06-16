# install.ps1 — cc-switch installer
# Copies cc-switch functions into pwsh $PROFILE and switch.md into Claude Code commands
# Run: .\install.ps1
# Or from web: irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex

param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoProfile,
    [switch]$NoSwitchMd
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== cc-switch Installer ===" -ForegroundColor Cyan
Write-Host ""

# === Copy cc-switch.ps1 to ~/.claude/ ===
$ccSwitchSrc = Join-Path $scriptDir "cc-switch.ps1"
$ccSwitchDst = "$env:USERPROFILE\.claude\cc-switch.ps1"

if (Test-Path $ccSwitchSrc) {
    Write-Host "[1/3] Installing cc-switch.ps1..." -ForegroundColor Yellow
    if (-not $DryRun) {
        Copy-Item $ccSwitchSrc $ccSwitchDst -Force
        Write-Host "  Copied to $ccSwitchDst" -ForegroundColor Green
    }
} else {
    Write-Host "[1/3] cc-switch.ps1 source not found at $ccSwitchSrc" -ForegroundColor Red
    Write-Host "  Skiping file copy (functions will be embedded in profile directly)" -ForegroundColor Gray
}

# === Inject into pwsh $PROFILE ===
if (-not $NoProfile) {
    Write-Host "[2/3] Updating PowerShell profile..." -ForegroundColor Yellow
    
    $profilePath = $PROFILE
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $marker = "# >>> cc-switch (auto-generated)"
    $endMarker = "# <<< cc-switch"

    $profileBlock = @"

$marker
# Dot-source standalone script (if copied)
if (Test-Path "$env:USERPROFILE\.claude\cc-switch.ps1") {
    . "$env:USERPROFILE\.claude\cc-switch.ps1"
} else {
    Write-Host "cc-switch: not installed. Run install.ps1 or clone https://github.com/luyuehm/cc-switch" -ForegroundColor Yellow
}
$endMarker
"@

    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw
        if ($existing -match [regex]::Escape($marker)) {
            Write-Host "  Profile already has cc-switch block. Use -Force to overwrite." -ForegroundColor Gray
        } else {
            if (-not $DryRun) {
                Add-Content $profilePath "`r`n$profileBlock"
                Write-Host "  Appended to $profilePath" -ForegroundColor Green
            }
        }
    } else {
        if (-not $DryRun) {
            $profileBlock | Set-Content $profilePath -Encoding UTF8
            Write-Host "  Created $profilePath" -ForegroundColor Green
        }
    }
}

# === Copy switch.md to Claude Code commands ===
if (-not $NoSwitchMd) {
    Write-Host "[3/3] Installing switch.md slash command..." -ForegroundColor Yellow
    $switchMdSrc = Join-Path $scriptDir "switch.md"
    $switchMdDst = "$env:USERPROFILE\.claude\commands\switch.md"

    if (Test-Path $switchMdSrc) {
        if (-not $DryRun) {
            $cmdDir = Split-Path $switchMdDst -Parent
            if (-not (Test-Path $cmdDir)) {
                New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
            }
            Copy-Item $switchMdSrc $switchMdDst -Force
            Write-Host "  Copied to $switchMdDst" -ForegroundColor Green
        }
    } else {
        Write-Host "  switch.md source not found, skipping." -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Done. Reload profile to activate:" -ForegroundColor Green
Write-Host "  . `$PROFILE" -ForegroundColor White
Write-Host ""
Write-Host "Then try:" -ForegroundColor Gray
Write-Host "  cc                # show menu" -ForegroundColor White
Write-Host "  cc gpt-5.5        # switch and launch" -ForegroundColor White
Write-Host "  cc-status         # model inventory" -ForegroundColor White
Write-Host ""
