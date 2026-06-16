# install.ps1 — cc-switch one-click installer
# Sets up: model switching, OAuth bypass, skill menu management, slash commands
# Run: .\install.ps1
# Web: irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex

param([switch]$SkipProfile)

Write-Host ""
Write-Host " ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   cc-switch — Claude Code Model + Menu Manager" -ForegroundColor Cyan
Write-Host " ═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# [1/5] Copy cc-switch.ps1 to ~/.claude/
Write-Host "[1/5] Installing core script to ~/.claude/cc-switch.ps1..." -ForegroundColor Yellow
if (-not (Test-Path "$env:USERPROFILE\.claude")) {
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude" | Out-Null
}
Copy-Item "$scriptDir\cc-switch.ps1" "$env:USERPROFILE\.claude\cc-switch.ps1" -Force
Write-Host "  ✅ Core script installed" -ForegroundColor Green

# [2/5] Copy cc-menu Python scripts (optional advanced features)
Write-Host ""
Write-Host "[2/5] Installing cc-menu skill management (optional advanced features)..." -ForegroundColor Yellow
$skillsDir = "$env:USERPROFILE\.claude\skills\cc-menu"
if (Test-Path $skillsDir) {
    Write-Host "  ℹ️  cc-menu skills already exist, skipping..." -ForegroundColor Gray
} else {
    if (Test-Path "$scriptDir\skills\cc-menu") {
        Copy-Item "$scriptDir\skills\cc-menu" $skillsDir -Recurse -Force
        Write-Host "  ✅ cc-menu skills installed to $skillsDir" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  cc-menu skills not found (optional, skipped)" -ForegroundColor Yellow
    }
}

# [3/5] Set up .env for secrets
Write-Host ""
Write-Host "[3/5] Setting up cc-switch.env for secrets..." -ForegroundColor Yellow
$envExample = "$scriptDir\.env.example"
$envTarget = "$env:USERPROFILE\.claude\cc-switch.env"
if (-not (Test-Path $envTarget)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample $envTarget
        Write-Host "  Created: $envTarget" -ForegroundColor Green
        Write-Host "  ✏️  Edit this file to set your:" -ForegroundColor Yellow
        Write-Host "      ANTHROPIC_API_KEY" -ForegroundColor Gray
        Write-Host "      ANTHROPIC_BASE_URL (or CPA_MODELS_URL)" -ForegroundColor Gray
    } else {
        Write-Host "  ⚠️  .env.example not found" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ℹ️  cc-switch.env already exists, skipping..." -ForegroundColor Gray
}

# [4/5] Update PowerShell profile
Write-Host ""
Write-Host "[4/5] Configuring PowerShell profile..." -ForegroundColor Yellow
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}

$ccBlock = @'
# >>> cc-switch — Claude Code Model + Menu Manager
# https://github.com/luyuehm/cc-switch
if (Test-Path "$env:USERPROFILE\.claude\cc-switch.ps1") {
    . "$env:USERPROFILE\.claude\cc-switch.ps1"
} else {
    Write-Host "[cc-switch] Not installed. Run: irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex" -ForegroundColor Yellow
}
# <<< cc-switch
'@

if (Test-Path $profilePath) {
    $content = Get-Content $profilePath -Raw
    if ($content -notlike "*cc-switch*") {
        Add-Content -Path $profilePath -Value "`n$ccBlock"
        Write-Host "  ✅ Appended to: $profilePath" -ForegroundColor Green
    } else {
        Write-Host "  ℹ️  cc-switch already in profile, skipping..." -ForegroundColor Gray
    }
} else {
    Set-Content -Path $profilePath -Value $ccBlock
    Write-Host "  ✅ Created: $profilePath" -ForegroundColor Green
}

# [5/5] Copy cc-switch.ps1 to D:/vscode project for development
Write-Host ""
Write-Host "[5/5] Linking to D:/vscode/cc-switch for development..." -ForegroundColor Yellow
if (Test-Path "$scriptDir\cc-switch.ps1") {
    # Already in the project, just confirm
    Write-Host "  ℹ️  Script location: $scriptDir" -ForegroundColor Gray
} else {
    Write-Host "  ℹ️  Running from: $scriptDir" -ForegroundColor Gray
}

Write-Host ""
Write-Host " ═══════════════════════════════════════════════" -ForegroundColor Green
Write-Host "   Installation Complete!" -ForegroundColor Green
Write-Host " ═══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit ~/.claude/cc-switch.env with your API key and CPA URL" -ForegroundColor White
Write-Host "  2. Reload profile: . `$PROFILE" -ForegroundColor White
Write-Host "  3. Try: cc gpt-5.5    (switch model + launch)" -ForegroundColor White
Write-Host "          cc            (show menu)" -ForegroundColor White
Write-Host "          cc-audit      (audit skill visibility)" -ForegroundColor White
Write-Host "          cc-profile minimal   (hide docs/examples)" -ForegroundColor White
Write-Host ""

if (-not $SkipProfile) {
    Write-Host "Reloading profile now..." -ForegroundColor Yellow
    . $profilePath
    Write-Host ""
    Write-Host "Tip: Run 'cc' to see the full menu" -ForegroundColor Cyan
}