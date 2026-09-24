# ================================================================
# PATH normalisation (runs for BOTH prompt engines)
# ================================================================
# NOTE: the old `$env:Path += ";C:\tools"` appended a duplicate every time a
# pwsh was nested inside another, and left the entry at the TAIL — so the older
# oh-my-posh v25 under "Program Files (x86)" won command resolution. Strip every
# copy and re-add exactly one at the FRONT.
$pathParts = @($env:Path -split ';' | Where-Object { $_ -and $_ -ne 'C:\tools' })
$env:Path = (@('C:\tools') + $pathParts) -join ';'

# ================================================================
# Prompt engine
#   'native' -> pure PowerShell prompt, no child processes (~2 ms/prompt)
#   'omp'    -> oh-my-posh theme (richer, ~90 ms/prompt)
# Switch at runtime with:   $PromptEngine='omp'; . $PROFILE
# (the default below only applies when the variable is not already set, so the
# live switch above is not overwritten by re-sourcing the profile)
# ================================================================
if (-not $PromptEngine) { $PromptEngine = 'native' }

if ($PromptEngine -eq 'omp') {
    # === Oh My Posh (prompt theme) ===
    # Binary is pinned to C:\tools (v29.15.1). The old v25.16.1 MSI install that
    # used to shadow it on PATH has been uninstalled. The v29 themes live next to
    # the binary, so POSH_THEMES_PATH is pointed there too.
    $ohMyPosh = "C:\tools\oh-my-posh.exe"
    $poshThemeDir = "C:\tools\oh-my-posh\themes"
    $poshTheme = Join-Path $poshThemeDir "powerlevel10k_rainbow.omp.json"
    if (Test-Path $ohMyPosh) {
        $env:POSH_THEMES_PATH = $poshThemeDir
        if (Test-Path $poshTheme) {
            & $ohMyPosh init pwsh --config $poshTheme | Invoke-Expression
        } else {
            & $ohMyPosh init pwsh | Invoke-Expression
        }
    }
}
elseif ($PromptEngine -eq 'native') {
    # === Native prompt — powerlevel10k_rainbow look, no child processes ===
    # Replicates the segments and colours of
    #   C:\tools\oh-my-posh\themes\powerlevel10k_rainbow.omp.json
    # but renders entirely in-process (~10 ms) instead of spawning
    # oh-my-posh.exe (~90 ms on EVERY Enter). Rendered shape:
    #
    #   ╭─   D:\repo  main ✔      1.2s   ✔   15:04:05      ─╮
    #   ╰─
    #
    # Layout notes:
    #  - .git/HEAD is read directly (~2 ms) so no git process is spawned for the
    #    branch. Dirty counts come from `git status` but are TTL-cached, because a
    #    full `git status` measures ~130 ms on the large repos on this machine.
    #  - the right-hand block is right-aligned by PADDING line 1 with spaces.
    #  - the closing ─╯ on line 2 is drawn with ESC7/ESC8 (save/restore cursor) so
    #    it never moves the real cursor; the last prompt line therefore stays a
    #    clean "╰─ " and PSReadLine's line editing keeps working.
    $script:GitStatusMode = 'cached'   # 'off' (fastest) | 'cached' | 'always'
    $script:GitStatusTtl  = 2.0        # seconds between `git status` refreshes
    $script:ExecTimeMinMs = 500        # show exec time only above this (omp default)
    $script:ShowGitStash  = $true
    $script:_gitPrompt    = @{ Key = $null; At = [datetime]::MinValue
                               Staged = 0; Modified = 0; Untracked = 0; Stash = 0
                               Ahead = 0; Behind = 0; HasUpstream = $false }

    # ---- palette straight out of the omp theme (#d3d7cf / #3465a4 / #4e9a06 ...) ----
    $script:P10k = @{
        Grey   = '211;215;207'   # #d3d7cf  frame / time
        Blue   = '52;101;164'    # #3465a4  path
        BlueFg = '228;228;228'   # #e4e4e4  path text
        Green  = '78;154;6'      # #4e9a06  clean git
        Yellow = '196;160;0'     # #c4a000  dirty git / exec-time bg
        Black  = '0;0;0'
        Red    = '204;34;34'     # #cc2222  failed status bg
    }

    # ---- glyphs (Nerd Font) ----
    $script:P10kGlyph = @{
        OS     = [char]0xF17A   # nf-fa-windows
        Folder = [char]0xF07C   # nf-fa-folder_open
        Git    = [char]0xF126   # nf-fa-code_fork
        Clock  = [char]0xF017   # nf-fa-clock
        Check  = [char]0xF42E   # nf-oct-check
        Timer  = [char]0xF252   # nf-fa-hourglass_half
        LArrow = [char]0xE0B0   # powerline right-pointing solid
        RArrow = [char]0xE0B2   # powerline left-pointing solid
    }

    # Visible width: strips ANSI and counts East-Asian wide chars as 2 columns,
    # so right-alignment stays correct for paths like D:\标书测评.
    function Get-P10kWidth {
        param([string]$Text)
        $t = [regex]::Replace($Text, "$([char]27)\[[0-9;]*m", '')
        $t = [regex]::Replace($t, "$([char]27)\].*?$([char]7)", '')
        $w = 0
        foreach ($ch in $t.ToCharArray()) {
            $c = [int]$ch
            if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0x303E) -or
                ($c -ge 0x3041 -and $c -le 0x33FF) -or ($c -ge 0x3400 -and $c -le 0x4DBF) -or
                ($c -ge 0x4E00 -and $c -le 0x9FFF) -or ($c -ge 0xA000 -and $c -le 0xA4CF) -or
                ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or ($c -ge 0x20000 -and $c -le 0x3FFFD)) { $w += 2 }
            else { $w += 1 }
        }
        $w
    }

    # One left-block powerline segment: separator arrow coloured as the previous
    # background, then the content on the new background.
    function New-P10kSeg {
        param([string]$PrevBg, [string]$Bg, [string]$Fg, [string]$Content)
        $e = [char]27
        "${e}[48;2;${Bg}m${e}[38;2;${PrevBg}m$($script:P10kGlyph.LArrow)${e}[0m${e}[48;2;${Bg}m${e}[38;2;${Fg}m${Content}${e}[0m"
    }

    # One right-block segment (inverted powerline: left-pointing arrow edge).
    function New-P10kRightSeg {
        param([string]$PrevBg, [string]$SegBg, [string]$SegFg, [string]$Content)
        $e = [char]27
        $edge = if ($PrevBg) { "${e}[48;2;${PrevBg}m" } else { '' }
        "${edge}${e}[38;2;${SegBg}m$($script:P10kGlyph.RArrow)${e}[0m${e}[48;2;${SegBg}m${e}[38;2;${SegFg}m${Content}${e}[0m"
    }

    function Get-VcsPromptInfo {
        # Returns branch + dirty counts, or $null outside a git repo.
        $startDir = $PWD.ProviderPath
        if (-not $startDir) { return $null }

        # Walk up to locate the repository root.
        $gitEntry = $null; $probe = $startDir
        while ($probe) {
            $cand = Join-Path $probe '.git'
            if (Test-Path -LiteralPath $cand) { $gitEntry = $cand; break }
            # NOTE: Split-Path has no parameter set combining -LiteralPath with
            # -Parent, so use the .NET call (also cheaper: no cmdlet overhead).
            $parent = [IO.Path]::GetDirectoryName($probe)
            if (-not $parent -or $parent -eq $probe) { break }
            $probe = $parent
        }
        if (-not $gitEntry) { return $null }

        # `.git` is a FILE for worktrees and submodules; it points elsewhere.
        if (-not (Test-Path -LiteralPath $gitEntry -PathType Container)) {
            $first = Get-Content -LiteralPath $gitEntry -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -match '^gitdir:\s*(.+)') {
                $gitEntry = $Matches[1].Trim()
                if (-not [IO.Path]::IsPathRooted($gitEntry)) {
                    $gitEntry = [IO.Path]::GetFullPath((Join-Path $probe $gitEntry))
                }
            } else { return $null }
        }

        # Branch comes straight from HEAD — no git process needed.
        $branch = $null
        $headFile = Join-Path $gitEntry 'HEAD'
        if (Test-Path -LiteralPath $headFile) {
            $head = Get-Content -LiteralPath $headFile -Raw -ErrorAction SilentlyContinue
            if     ($head -match 'ref:\s*refs/heads/(\S+)') { $branch = $Matches[1] }
            elseif ($head -match '^\s*([0-9a-fA-F]{7,})')   { $branch = $Matches[1].Substring(0, 7) + '…' }
        }
        if (-not $branch) { $branch = 'HEAD' }

        # Stash count needs no git process: the reflog for refs/stash has one
        # line per entry.
        $stash = 0
        if ($script:ShowGitStash) {
            $stashLog = Join-Path $gitEntry 'logs/refs/stash'
            if (Test-Path -LiteralPath $stashLog) {
                $stash = @(Get-Content -LiteralPath $stashLog -ErrorAction SilentlyContinue).Count
            }
        }

        # Dirty counts are cached per-repo (index/gitdir), refreshed after the TTL.
        $staged = 0; $modified = 0; $untracked = 0
        $ahead = 0; $behind = 0; $hasUpstream = $false
        if ($script:GitStatusMode -ne 'off') {
            $stale = ($script:_gitPrompt.Key -ne $gitEntry) -or
                     ($script:GitStatusMode -eq 'always') -or
                     (([datetime]::Now - $script:_gitPrompt.At).TotalSeconds -gt $script:GitStatusTtl)
            if ($stale) {
                $ahead = 0; $behind = 0; $hasUpstream = $false
                # `-b` prepends a "## branch...upstream [ahead N, behind M]" line,
                # so upstream divergence comes from the SAME call (no extra git run).
                foreach ($ln in (git -C $startDir status --porcelain=v1 -b --untracked-files=normal 2>$null)) {
                    if ($ln.StartsWith('## ')) {
                        $head = $ln.Substring(3)
                        if ($head -match '\.\.\.') { $hasUpstream = $true }
                        if ($head -match '\[ahead (\d+)(?:, behind (\d+))?\]') {
                            $ahead  = [int]$Matches[1]
                            if ($Matches[2]) { $behind = [int]$Matches[2] }
                        } elseif ($head -match '\[behind (\d+)\]') {
                            $behind = [int]$Matches[1]
                        }
                        continue
                    }
                    if ($ln.Length -lt 2) { continue }
                    $x = $ln.Substring(0, 1); $y = $ln.Substring(1, 1)
                    if ($x -eq '?' -and $y -eq '?') { $untracked++ }
                    else {
                        if ($x -ne ' ' -and $x -ne '?') { $staged++ }
                        if ($y -ne ' ' -and $y -ne '?') { $modified++ }
                    }
                }
                $script:_gitPrompt.Key = $gitEntry
                $script:_gitPrompt.At = [datetime]::Now
                $script:_gitPrompt.Staged = $staged
                $script:_gitPrompt.Modified = $modified
                $script:_gitPrompt.Untracked = $untracked
                $script:_gitPrompt.Ahead = $ahead
                $script:_gitPrompt.Behind = $behind
                $script:_gitPrompt.HasUpstream = $hasUpstream
            } else {
                $staged    = $script:_gitPrompt.Staged
                $modified  = $script:_gitPrompt.Modified
                $untracked = $script:_gitPrompt.Untracked
                $ahead     = $script:_gitPrompt.Ahead
                $behind    = $script:_gitPrompt.Behind
                $hasUpstream = $script:_gitPrompt.HasUpstream
            }
        }
        [pscustomobject]@{
            Branch = $branch
            Staged = $staged; Modified = $modified; Untracked = $untracked; Stash = $stash
            Ahead = $ahead; Behind = $behind; HasUpstream = $hasUpstream
        }
    }

    # Renders:
    #   ╭─   D:\repo  main ✔  ✚2 ✖1      1.2s   ✔   15:04:05      ─╮
    #   ╰─
    function global:prompt {
        $lastExit = $LASTEXITCODE
        $e = [char]27
        $reset = "${e}[0m"
        $C = $script:P10k
        $G = $script:P10kGlyph

        # This prompt spans 2 terminal lines; tell PSReadLine once (the same thing
        # oh-my-posh's init does) so its cursor bookkeeping stays correct. Done
        # lazily here because PSReadLine is not guaranteed to be loaded when the
        # profile itself is sourced.
        if (-not $script:_readlineConfigured) {
            # flag only on success, so a too-early first prompt retries later
            try { Set-PSReadLineOption -ExtraPromptLineCount 1; $script:_readlineConfigured = $true } catch { }
        }

        # ---------- working directory ----------
        $loc = $PWD
        if ($loc.Provider.Name -ne 'FileSystem') {
            $pathText = "$($loc.Provider.Name)::$($loc.Path)"
        } else {
            $pathText = $loc.ProviderPath
            if ($pathText.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
                $pathText = '~' + $pathText.Substring($HOME.Length)
            }
            # condense long paths down to <root>…\<parent>\<leaf>
            $segs = $pathText -split '[\\/]'
            if ($segs.Count -gt 4) { $pathText = "$($segs[0])…\$($segs[-2])\$($segs[-1])" }
        }

        # ---------- left block: ╭─ OS  path  git ----------
        $git = Get-VcsPromptInfo
        $left = [System.Text.StringBuilder]::new()
        # OS segment, introduced by the ╭─ +  diamond in the frame colour
        [void]$left.Append("${e}[38;2;$($C.Grey)m╭─$($G.RArrow)${e}[0m")
        [void]$left.Append("${e}[48;2;$($C.Grey)m${e}[38;2;$($C.Black)m $($G.OS) ${e}[0m")
        # path segment
        [void]$left.Append((New-P10kSeg -PrevBg $C.Grey -Bg $C.Blue -Fg $C.BlueFg -Content " $($G.Folder) $pathText "))
        # git segment (yellow when dirty, like the theme's background_templates)
        if ($git) {
            $gitBg = if ($git.Staged -or $git.Modified -or $git.Untracked) { $C.Yellow } else { $C.Green }
            $gitTxt = " $($G.Git) $($git.Branch)"
            # upstream status, like the theme's BranchStatus: ≡ in sync, ↑n / ↓n
            $bs = @()
            if ($git.Ahead)  { $bs += "↑$($git.Ahead)" }
            if ($git.Behind) { $bs += "↓$($git.Behind)" }
            if (-not $bs.Count -and $git.HasUpstream) { $bs += '≡' }
            if ($bs.Count) { $gitTxt += ' ' + ($bs -join '') }
            $marks = @()
            if ($git.Untracked) { $marks += "… $($git.Untracked)" }
            if ($git.Modified)  { $marks += "$([char]0xF044) $($git.Modified)" }
            if ($git.Staged)    { $marks += "$([char]0xF046) $($git.Staged)" }
            if ($marks.Count) { $gitTxt += ' ' + ($marks -join ' ') }
            if ($script:ShowGitStash -and $git.Stash -gt 0) { $gitTxt += " $([char]0xEB4B) $($git.Stash)" }
            $gitTxt += ' '
            [void]$left.Append((New-P10kSeg -PrevBg $C.Blue -Bg $gitBg -Fg $C.Black -Content $gitTxt))
            $leftTail = $gitBg
        } else {
            $leftTail = $C.Blue
        }
        [void]$left.Append("${e}[38;2;${leftTail}m$($G.LArrow)${e}[0m")

        # ---------- right block: exec-time  status  clock ─╮ ----------
        $right = [System.Text.StringBuilder]::new()
        $prevBg = $null

        # execution time of the previous command (from PSReadLine history — no
        # extra process, unlike spawning `time`/measuring wall clock by hand)
        if ($script:ExecTimeMinMs -gt 0) {
            $h = Get-History -Count 1
            if ($h -and $h.StartExecutionTime -and $h.EndExecutionTime) {
                $ms = ($h.EndExecutionTime - $h.StartExecutionTime).TotalMilliseconds
                if ($ms -ge $script:ExecTimeMinMs) {
                    $dur = if     ($ms -ge 60000) { '{0}m{1:00}s' -f [int]($ms / 60000), [int](($ms % 60000) / 1000) }
                           elseif ($ms -ge 1000)  { '{0:0.0}s' -f ($ms / 1000) }
                           else                   { '{0}ms' -f [int]$ms }
                    [void]$right.Append((New-P10kRightSeg -PrevBg $prevBg -SegBg $C.Yellow -SegFg $C.Black -Content " $dur $($G.Timer) "))
                    $prevBg = $C.Yellow
                }
            }
        }

        # status (always shown: ✔ on success, red ✘ <code> on failure)
        if ($lastExit -gt 0) {
            [void]$right.Append((New-P10kRightSeg -PrevBg $prevBg -SegBg $C.Red -SegFg $C.Grey -Content " ✘ $lastExit "))
            $prevBg = $C.Red
        } else {
            [void]$right.Append((New-P10kRightSeg -PrevBg $prevBg -SegBg $C.Black -SegFg $C.Grey -Content " $($G.Check) "))
            $prevBg = $C.Black
        }

        # clock
        [void]$right.Append((New-P10kRightSeg -PrevBg $prevBg -SegBg $C.Grey -SegFg $C.Black -Content " $(Get-Date -Format 'HH:mm:ss') $($G.Clock) "))
        [void]$right.Append("${e}[38;2;$($C.Grey)m$($G.LArrow)─╮${e}[0m")

        # ---------- assemble: right block padded to the far right ----------
        $width = 0
        try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
        if ($width -le 0) { $width = 120 }

        $leftText  = $left.ToString()
        $rightText = $right.ToString()
        $lw = Get-P10kWidth $leftText
        $rw = Get-P10kWidth $rightText

        $pad = $width - $lw - $rw - 1          # -1 keeps one column spare (no wrap)
        if ($pad -lt 1) { $rightText = ''; $rw = 0; $pad = 0 }
        $line1 = $leftText + (' ' * $pad) + $rightText

        # ---------- line 2: ╰─ (input line) with ─╯ echoed at the right ----------
        # The ─╯ is drawn between ESC7 (save cursor) and ESC8 (restore cursor) so
        # it does not move the real cursor — PSReadLine only ever sees "╰─ ".
        $line2 = "${e}[38;2;$($C.Grey)m╰─ ${e}[0m"
        if ($rw -gt 0 -and $width -gt 12) {
            $rpad = $width - 6                 # 3 ('╰─ ') + rpad + 2 ('─╯'), 1 col spare
            if ($rpad -lt 1) { $rpad = 0 }
            $line2 += "${e}7" + (' ' * $rpad) + "${e}[38;2;$($C.Grey)m─╯${e}[0m${e}8"
        }

        # window title (the theme's console_title_template)
        try { $Host.UI.RawUI.WindowTitle = "pwsh — $(Split-Path -Leaf $pathText)" } catch { }

        $line1 + "`n" + $line2
    }
}

# === Terminal Icons (file/dir icons in ls) — LAZY LOAD ===
# Importing Terminal-Icons costs ~700 ms at startup: it parses ~780 KB of
# PowerShell (Terminal-Icons.psm1 206 KB + Data/glyphs.ps1 571 KB, 9253 entries)
# AND rewrites ~180 KB of theme XML to disk on every single load. We therefore
# defer it: the module is imported on the FIRST file listing, not at shell start.
$script:TerminalIconsLoaded = $false
function global:Get-ChildItem {
    if (-not $script:TerminalIconsLoaded) {
        $script:TerminalIconsLoaded = $true
        Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    }
    Microsoft.PowerShell.Management\Get-ChildItem @args
}

# === zoxide (smart cd) ===
if (Test-Path "C:\tools\zoxide.exe") {
    # idempotent: a plain `+= ";C:\tools"` duplicated the entry every time a new
    # pwsh was nested inside an existing one (PATH grew unbounded)
    if (-not ($env:Path -split ';' | Where-Object { $_ -eq 'C:\tools' })) {
        $env:Path = "C:\tools;$env:Path"
    }
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
        $r = Test-Connection $Target -Count 1 -ErrorAction SilentlyContinue
        if ($r) {
            $success++
            # NOTE: PowerShell 7's Test-Connection returns PingReply objects
            # whose latency lives in .Latency — there is no .RoundtripTime
            # property (that name was Windows PowerShell only), and the old
            # code pinged a SECOND time just to read it.
            $results += $r.Latency
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
    # NOTE: Measure-Object -StandardDeviation needs >= 2 samples, so guard it
    # (the old code called it unconditionally and threw on a single ping).
    $valid = @($results | Where-Object { $null -ne $_ })
    if ($valid.Count -gt 0) {
        $avg = ($valid | Measure-Object -Average).Average
        $jitter = if ($valid.Count -ge 2) { ($valid | Measure-Object -StandardDeviation).StandardDeviation } else { 0 }
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
        [Parameter(Position=1)]
        [string]$Path = ".",
        [string[]]$Include = @("*"),
        [switch]$IgnoreCase
    )

    # NOTE: Select-String is case-insensitive by default, so -IgnoreCase is a
    # no-op. The old $flags array was built but never passed to any command.
    Select-String -Path (Join-Path $Path "*") -Pattern $Pattern -Include $Include -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "$($_.FileName):$($_.LineNumber): $($_.Line.Trim())" -ForegroundColor White
    }
}
# NOTE: there is deliberately NO `Set-Alias grep Grep` here. PowerShell command
# names are case-insensitive, so an alias named `grep` and the function `Grep`
# are the SAME name; the alias shadowed the function and pointed back at itself,
# making both `grep` and `Grep` fail with "term 'grep' is not recognized".
# The function below already answers to both spellings on its own.

function GrepR {
    <#
    .SYNOPSIS
        Recursive grep with line numbers.
    .EXAMPLE
        GrepR "function" .\src -Include *.ps1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$Pattern,
        [Parameter(Position=1)]
        [string]$Path = ".",
        [string[]]$Include = @("*"),
        [switch]$IgnoreCase
    )

    # NOTE: Select-String has NO -Recurse parameter, so the old
    # `Select-String ... -Recurse` always threw "parameter cannot be found".
    # Recursion must come from Get-ChildItem, whose output is piped in.
    # (Select-String is case-insensitive by default, so -IgnoreCase is a no-op.)
    Get-ChildItem -Path $Path -Include $Include -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -Pattern $Pattern -ErrorAction SilentlyContinue | ForEach-Object {
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
        # NOTE: the old form passed a PowerShell hashtable @{path="..."} as a
        # literal git argument; git only understands the raw range.
        $ahead = git rev-list --count --left-right HEAD...origin/HEAD 2>&1
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
    # NOTE: some drives (virtual / non-filesystem-backed mounts) report
    # Used + Free = 0, which made the old $_.Used / ($_.Used + $_.Free)
    # throw "Attempted to divide by zero". Skip those entries.
    Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Root -match "^\\\\|^C:|^D:|^E:" -and $null -ne $_.Used -and ($_.Used + $_.Free) -gt 0 } |
        ForEach-Object {
            $totalBytes = $_.Used + $_.Free
            $usage = [math]::Round(($_.Used / $totalBytes) * 100, 1)
            $total = [math]::Round($totalBytes / 1GB, 1)
            $free = [math]::Round($_.Free / 1GB, 1)
            $color = if ($usage -gt 90) { "Red" } elseif ($usage -gt 75) { "Yellow" } else { "Green" }
            Write-Host "  $($_.Name): `t${total}GB (${usage}% used, ${free}GB free)" -ForegroundColor $color
        }

    Write-Host ""
}

# --- 5. Quick Shortcuts & Aliases ---

# Common aliases
# NOTE: Set-Alias' target must be a plain COMMAND NAME — it cannot carry
# arguments and cannot be a path. `Set-Alias ll 'Get-ChildItem -Force'` was
# broken (it tried to run a command literally named "Get-ChildItem -Force"),
# so the wrappers below are functions instead.
function ll  { Get-ChildItem -Force @args }            # detailed listing
function lsa { Get-ChildItem -Force -Recurse @args }   # recursive listing
Set-Alias cat Get-Content
if (Get-Command code -ErrorAction SilentlyContinue) {
    Set-Alias vi  code                                 # open in VS Code
    Set-Alias vim code
}
# (gs is defined once, next to Get-GitStatus above)

# Directory shortcuts — these folders are on D:\ on Windows; the old
# '/mnt/d/...' values were WSL-style paths and never worked in this shell.
function pro { Set-Location 'D:\vscode' }                  # Projects
function obs { Set-Location 'D:\obsidian-vault' }          # Obsidian vault
function pub { Set-Location 'D:\prometheus_report_cache' } # Prometheus reports

# Quick navigate
function Open-Root {
    # Open VS Code at project root
    Set-Location 'D:\vscode'
    code .
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
        "Nav:          pro   -> D:\vscode",
        "              obs   -> D:\obsidian-vault",
        "              pub   -> D:\prometheus_report_cache",
        "              Open-Root -> cd D:\vscode + code .",
        "Other:        Get-Prompt   (this menu)"
    )
    $functions | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host ""

    # Aliases
    Write-Host "=== Aliases ===" -ForegroundColor Cyan
    $aliases = @(
        "ls/dir/gci -> Get-ChildItem",
        "ll         -> Get-ChildItem -Force        (function)",
        "lsa        -> Get-ChildItem -Force -Recurse (function)",
        "cat        -> Get-Content",
        "grep/Grep  -> Grep   function (wraps Select-String; both cases work)",
        "gr         -> GrepR  (recursive grep)",
        "gs         -> Get-GitStatus",
        "vi/vim     -> code (VS Code, only if 'code' is on PATH)",
        "pro/obs/pub -> cd D:\vscode | D:\obsidian-vault | D:\prometheus_report_cache",
        "cc         -> cc-switch menu",
        "cc-theme   -> Theme switch",
        "cc-sync    -> CPA model sync",
        "cc-hide    -> Hide skill",
        "cc-show    -> Show skill"
    )
    $aliases | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host ""

    # Prompt engine
    Write-Host "=== Prompt ===" -ForegroundColor Cyan
    Write-Host "  当前引擎: $PromptEngine" -ForegroundColor White
    Write-Host "  切换    : `$PromptEngine='omp'; . `$PROFILE   (oh-my-posh)" -ForegroundColor DarkGray
    Write-Host "            `$PromptEngine='native'; . `$PROFILE  (fast, built-in)" -ForegroundColor DarkGray
    Write-Host ""
}
# Note: 'prompt' is a reserved function name in pwsh — do NOT alias to it
Set-Alias pwsh-help Get-Prompt
Set-Alias my-help Get-Prompt

# --- 7. Colorful Prompt Enhancement ---

# Custom prompt that shows working directory and git branch
function global:enhanced-prompt {
    $dir = Split-Path (Get-Location) -Leaf
    $color = if ($?) { "Green" } else { "Red" }
    $branch = try { git rev-parse --abbrev-ref HEAD 2>$null } catch { "" }
    $c = [char]0x276F

    if ($branch -and $branch -ne "HEAD") {
        "$dir ($branch) $c "
    } else {
        "$dir $c "
    }
}

# Enable this if you want the enhanced prompt (overrides Oh My Posh for specific features)
# Set-PSReadLineOption -Colors @{Command = 'Cyan'; Parameter = 'Yellow'; String = 'Green' }
# Set-PSReadLineOption -PredictionSource History
# $function:prompt = { enhanced-prompt }

# ================================================================
# End of Utilities
# ================================================================
