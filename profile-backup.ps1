# === Oh My Posh (prompt theme) ===
$ohMyPosh = "C:\tools\oh-my-posh.exe"
$poshTheme = "C:\tools\oh-my-posh\themes\powerlevel10k_rainbow.omp.json"
if (Test-Path $ohMyPosh) {
    if (Test-Path $poshTheme) {
        & $ohMyPosh init pwsh --config $poshTheme | Invoke-Expression
    } else {
        & $ohMyPosh init pwsh | Invoke-Expression
    }
}

# === Terminal Icons (file/dir icons in ls) ===
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
}

# === zoxide (smart cd) ===
if (Test-Path "C:\tools\zoxide.exe") {
    $env:Path += ";C:\tools"
    Invoke-Expression (& { (C:\tools\zoxide.exe init powershell | Out-String) })
}

# >>> cc-switch — Claude Code Model Switcher + OAuth Bypass
# https://github.com/luyuehm/cc-switch
if (Test-Path "$env:USERPROFILE\.claude\cc-switch.ps1") {
    . "$env:USERPROFILE\.claude\cc-switch.ps1"
} else {
    Write-Host "[cc-switch] Not installed. Run: irm https://raw.githubusercontent.com/luyuehm/cc-switch/main/install.ps1 | iex" -ForegroundColor Yellow
}
# <<< cc-switch

# ================================================================
# pwsh Utilities — Ant Rich's Collection
# ================================================================

# --- 1. Network Diagnostics ---

function Get-NetworkStatus {
    <#
    .SYNOPSIS
        Network diagnostics: ping, latency, DNS, traceroute.
    .EXAMPLE
        Get-NetworkStatus google.com
        Get-NetworkStatus
    #>
    param([string]$Target = "google.com")

    Write-Host "`n=== Network Diagnostics for $Target ===" -ForegroundColor Cyan

    # Ping + latency
    $pings = Test-Connection $Target -Count 6 -ErrorAction SilentlyContinue
    if ($pings) {
        $avg = ($pings.RoundtripTime | Measure-Object -Average).Average
        $max = ($pings.RoundtripTime | Measure-Object -Maximum).Maximum
        $min = ($pings.RoundtripTime | Measure-Object -Minimum).Minimum
        Write-Host "  Ping:    OK" -ForegroundColor Green
        Write-Host "  Latency: avg=$([int]$avg)ms  min=$([int]$min)ms  max=$([int]$max)ms" -ForegroundColor Yellow
    } else {
        Write-Host "  Ping:    FAIL" -ForegroundColor Red
    }

    # DNS
    try {
        $dns = [System.Net.Dns]::GetHostEntry($Target)
        Write-Host "  DNS:     $($dns.AddressList -join ', ')" -ForegroundColor White
    } catch {
        Write-Host "  DNS:     FAILED" -ForegroundColor Red
    }

    # Traceroute
    Write-Host "  Traceroute:" -ForegroundColor White
    try {
        tracert $Target 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } catch {
        Write-Host "    unavailable" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Test-Port {
    <#
    .SYNOPSIS
        Test if a host's port is open.
    .EXAMPLE
        Test-Port google.com -Ports @(80, 443, 8080)
        Test-Port localhost 3306
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Host,
        [int[]]$Ports = @(22, 80, 443, 8080, 3306),
        [int]$Timeout = 1000
    )

    Write-Host "`n=== Port Check: $Host ===" -ForegroundColor Cyan
    $Ports | ForEach-Object {
        $port = $_
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $result = $tcp.BeginConnect($Host, $port, $null, $null)
            $ok = $result.AsyncWaitHandle.WaitOne($Timeout) -and $tcp.Connected
        } catch { $ok = $false } finally { $tcp.Close() }

        if ($ok) {
            Write-Host "  $Host : $port`t-> OPEN" -ForegroundColor Green
        } else {
            Write-Host "  $Host : $port`t-> CLOSED" -ForegroundColor Red
        }
    }
    Write-Host ""
}

function Get-PingStats {
    <#
    .SYNOPSIS
        Continuous ping for packet loss / jitter monitoring.
    .EXAMPLE
        Get-PingStats google.com -Count 50 -Interval 0.5
    #>
    param(
        [string]$Target = "google.com",
        [int]$Count = 20,
        [double]$Interval = 1
    )

    Write-Host "`n=== Ping Monitor: $Target ($Count pings) ===" -ForegroundColor Cyan

    $results = @()
    $success = 0
    $failures = 0

    for ($i = 1; $i -le $Count; $i++) {
        $r = Test-Connection $Target -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($r) {
            $success++
            $lat = (Test-Connection $Target -Count 1 | Select-Object -ExpandProperty RoundtripTime)
            $results += $lat
            $status = "OK"
        } else {
            $failures++
            $results += $null
            $status = "FAIL"
        }

        # Progress
        $pct = [int]($i / $Count * 100)
        Write-Host "`r  [$pct%] Ping: $status  Success: $success/$Count  Loss: $failures" -NoNewline -ForegroundColor White
        Start-Sleep -Seconds $Interval
    }

    Write-Host ""
    $loss = [math]::Round($failures / $Count * 100)
    if ($results | Where-Object { $_ -ne $null }) {
        $avg = ($results | Where-Object { $_ -ne $null } | Measure-Object -Average).Average
        $jitter = ($results | Where-Object { $_ -ne $null } | Measure-Object -StandardDeviation).StandardDeviation
        Write-Host "  Results: success=$success  loss=$failures ($loss%)  avg=${avg:2}ms  jitter=${jitter:2}ms" -ForegroundColor $(if ($loss -eq 0) { "Green" } else { "Yellow" })
    } else {
        Write-Host "  All $Count pings failed." -ForegroundColor Red
    }
    Write-Host ""
}

# --- 2. File & Directory Utilities ---

function Get-FileSizeSummary {
    <#
    .SYNOPSIS
        Show file/folder size summary.
    .EXAMPLE
        Get-FileSizeSummary .\Downloads
        Get-FileSizeSummary -Depth 3
    #>
    [CmdletBinding()]
    param(
        [string]$Path = ".",
        [int]$Depth = 1
    )

    $dir = Get-Item $Path
    $total = 0
    $files = 0
    $folders = 0

    Write-Host "`n=== Size: $($dir.Name) ===" -ForegroundColor Cyan

    Get-ChildItem $Path -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            $folders++
        } else {
            $files++
            $total += $_.Length
        }
    }

    Write-Host "  Folders: $folders" -ForegroundColor White
    Write-Host "  Files:   $files" -ForegroundColor White
    Write-Host "  Total:   $([math]::Round($total / 1MB, 2)) MB" -ForegroundColor Yellow
    Write-Host ""
}

function Grep {
    <#
    .SYNOPSIS
        Grep-like search across files (alias to Select-String).
    .EXAMPLE
        Grep "TODO" .\src -Include *.py
        Grep "error" *.log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Pattern,
        [string]$Path = ".",
        [string[]]$Include = @("*"),
        [switch]$IgnoreCase
    )

    $flags = @()
    if ($IgnoreCase) { $flags += "IgnoreCase" }
    Select-String -Path (Join-Path $Path "*") -Pattern $Pattern -Include $Include -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "$($_.FileName):$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor White
    }
}
Set-Alias grep Grep

function GrepR {
    <#
    .SYNOPSIS
        Recursive grep with line numbers.
    .EXAMPLE
        GrepR "function" .\src -Include *.ps1
    #>
    [CmdletBinding()]
    param(
        [string]$Pattern,
        [string]$Path = ".",
        [string[]]$Include = @("*"),
        [switch]$IgnoreCase
    )

    $flags = @()
    if ($IgnoreCase) { $flags += "IgnoreCase" }
    Select-String -Path (Join-Path $Path "*") -Pattern $Pattern -Include $Include -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "$($_.FileName):$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor White
    }
}
Set-Alias gr GrepR

# --- 3. Git Utilities ---

function Get-GitStatus {
    <#
    .SYNOPSIS
        Pretty git status with branch, ahead/behind, short log.
    .EXAMPLE
        Get-GitStatus
        Get-GitStatus -NumCommits 5
    #>
    [CmdletBinding()]
    param([int]$NumCommits = 3)

    try {
        $branch = git rev-parse --abbrev-ref HEAD 2>&1
        $ahead = git rev-list --count --left-right @{path="HEAD...origin/HEAD"} 2>&1
        $aheadNum = if ($ahead) { ($ahead -split ' ')[0] } else { 0 }
        $behindNum = if ($ahead) { ($ahead -split ' ')[1] } else { 0 }

        Write-Host "`n" -NoNewline

        # Branch
        $branchColor = if ($branch -match "detached") { "Yellow" } else { "Cyan" }
        Write-Host "  Branch:  " -NoNewline -ForegroundColor White
        Write-Host "$branch" -ForegroundColor $branchColor

        # Ahead/Behind
        if ($aheadNum -gt 0 -or $behindNum -gt 0) {
            if ($aheadNum -gt 0) {
                Write-Host "  Ahead:   +" -NoNewline -ForegroundColor Green
                Write-Host "$aheadNum" -NoNewline
            }
            if ($behindNum -gt 0) {
                Write-Host "  Behind:  " -NoNewline -ForegroundColor Red
                Write-Host "-$behindNum"
            }
        } else {
            Write-Host "  Status:  up to date" -ForegroundColor Green
        }

        # Short log
        Write-Host "  Recent:  " -NoNewline -ForegroundColor White
        $commits = git log --oneline -n $NumCommits 2>&1
        if ($commits) {
            $commits -split "`n" | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkGray
            }
        }

        Write-Host ""
    } catch {
        Write-Host "  Not a git repository." -ForegroundColor Yellow
        Write-Host ""
    }
}
Set-Alias gs Get-GitStatus

function Gc {
    <#
    .SYNOPSIS
        Git commit with message (alias).
    .EXAMPLE
        Gc "fix: resolve crash on null"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Message
    )

    Write-Host "  git add ." -ForegroundColor DarkGray
    git add . 2>&1 | Write-Host
    Write-Host "  git commit -m `"$Message`"" -ForegroundColor DarkGray
    git commit -m $Message 2>&1 | Write-Host
}

# --- 4. Process & System Utilities ---

function Top-Processes {
    <#
    .SYNOPSIS
        Show top N processes by CPU or Memory.
    .EXAMPLE
        Top-Processes -Top 10 -By CPU
        Top-Processes -Top 15 -By Memory
    #>
    [CmdletBinding()]
    param(
        [int]$Top = 10,
        [ValidateSet("CPU", "Memory")]
        [string]$By = "Memory"
    )

    Write-Host "`n=== Top $Top Processes (by $By) ===" -ForegroundColor Cyan

    $procs = Get-Process | Where-Object { -not $_.MainWindowTitle -and $_.Id -ne 0 }

    if ($By -eq "CPU") {
        $procs = $procs | Sort-Object CPU -Descending | Select-Object -First $Top
        Write-Host ("{0,-30} {1,10} {2,12}" -f "Name", "CPU(s)", "Memory(MB)") -ForegroundColor Gray
    } else {
        $procs = $procs | Sort-Object WorkingSet -Descending | Select-Object -First $Top
        Write-Host ("{0,-30} {1,10} {2,12}" -f "Name", "CPU(s)", "Memory(MB)") -ForegroundColor Gray
    }

    $procs | ForEach-Object {
        $memMB = [math]::Round($_.WorkingSet / 1MB, 1)
        Write-Host ("{0,-30} {1,10} {2,12}" -f $_.Name, [math]::Round($_.CPU, 2), $memMB)
    }
    Write-Host ""
}

function Get-SystemInfo {
    <#
    .SYNOPSIS
        System information: OS, RAM, CPU, disk usage.
    .EXAMPLE
        Get-SystemInfo
    #>
    Write-Host "`n=== System Info ===" -ForegroundColor Cyan

    # OS
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "  OS:        $($os.Caption) $($os.Version)" -ForegroundColor White
    Write-Host "  PowerShell: $((Get-Host).Version)" -ForegroundColor White

    # RAM
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Host "  RAM:       ${totalGB}GB total, ${freeGB}GB free" -ForegroundColor White

    # CPU
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Host "  CPU:       $($cpu.Name) ($($cpu.NumberOfCores) cores)" -ForegroundColor White

    # Disk
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^\\\\|^C:|^D:|^E:" } | ForEach-Object {
        $usage = [math]::Round(($_.Used / ($_.Used + $_.Free)) * 100, 1)
        $total = [math]::Round(($_.Used + $_.Free) / 1GB, 1)
        $free = [math]::Round($_.Free / 1GB, 1)
        $color = if ($usage -gt 90) { "Red" } elseif ($usage -gt 75) { "Yellow" } else { "Green" }
        Write-Host "  $($_.Name): `t${total}GB (${usage}% used, ${free}GB free)" -ForegroundColor $color
    }

    Write-Host ""
}

# --- 5. Quick Shortcuts & Aliases ---

# Common aliases
Set-Alias ll 'Get-ChildItem -Force'          # detailed listing
Set-Alias lsa 'Get-ChildItem -Recurse -Force' # recursive listing
Set-Alias vi 'code'                           # open in VS Code
Set-Alias vim 'code'
Set-Alias cat 'Get-Content'
Set-Alias gs Get-GitStatus                    # git status alias already above

# Directory shortcuts (add your own)
Set-Alias pro '/mnt/d/vscode'                 # Projects
Set-Alias obs '/mnt/d/obsidian-vault'         # Obsidian vault
Set-Alias pub '/mnt/d/prometheus_report_cache' # Prometheus reports

# Quick navigate
function Open-Root {
    # Open VS Code at project root
    code /mnt/d/vscode
}

# --- 6. Quick Prompts ---

function Get-Prompt {
    <#
    .SYNOPSIS
        Quick reference: all available functions and aliases.
    .EXAMPLE
        Get-Prompt
    #>
    Write-Host "`n" -NoNewline

    # Functions
    Write-Host "=== Functions ===" -ForegroundColor Cyan
    $functions = @(
        "Network:      Get-NetworkStatus <host>",
        "              Test-Port <host> [-Ports @(80,443,8080)]",
        "              Get-PingStats <host> [-Count 50]",
        "File:         Get-FileSizeSummary [-Depth 2]",
        "              Grep <pattern> [-Include *.py]",
        "              GrepR <pattern>  (recursive, alias: gr)",
        "Git:          Get-GitStatus     (alias: gs)",
        "              Gc 'commit msg'    (git add + commit)",
        "System:       Top-Processes [-Top 10] [-By CPU|Memory]",
        "              Get-SystemInfo",
        "Nav:          pro   -> /mnt/d/vscode",
        "              obs   -> /mnt/d/obsidian-vault",
        "              pub   -> /mnt/d/prometheus_report_cache",
        "              Open-Root -> code /mnt/d/vscode",
        "Other:        Get-Prompt   (this menu)"
    )
    $functions | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host ""

    # Aliases
    Write-Host "=== Aliases ===" -ForegroundColor Cyan
    $aliases = @(
        "ls/ll/lsa  -> Get-ChildItem",
        "cat        -> Get-Content",
        "grep/gr    -> Select-String",
        "gs         -> Get-GitStatus",
        "vi/vim     -> code (VS Code)",
        "pro/obs/pub -> Directory shortcuts",
        "cc         -> cc-switch menu",
        "cc-theme   -> Theme switch",
        "cc-sync    -> CPA model sync",
        "cc-hide    -> Hide skill",
        "cc-show    -> Show skill"
    )
    $aliases | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host ""
}
Set-Alias prompt Get-Prompt

# --- 7. Colorful Prompt Enhancement ---

# Custom prompt that shows working directory and git branch
function global:enhanced-prompt {
    $dir = Split-Path (Get-Location) -Leaf
    $color = if ($?) { "Green" } else { "Red" }
    $branch = try { git rev-parse --abbrev-ref HEAD 2>$null } catch { "" }

    if ($branch -and $branch -ne "HEAD") {
        "$dir ($branch) $([char]0x276F) " -ForegroundColor $color
    } else {
        "$dir $([char]0x276F) " -ForegroundColor $color
    }
}

# Enable this if you want the enhanced prompt (overrides Oh My Posh for specific features)
# Set-PSReadLineOption -Colors @{Command = 'Cyan'; Parameter = 'Yellow'; String = 'Green' }
# Set-PSReadLineOption -PredictionSource History
# $function:prompt = { enhanced-prompt }

# ================================================================
# End of Utilities
# ================================================================
