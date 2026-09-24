---
name: pwsh-startup-hang-fix
description: '诊断并修复 PowerShell (pwsh) 启动慢 / 卡顿（profile 加载数百毫秒到数秒）。覆盖三类根因：Terminal-Icons 等大型模块的同步导入（每次启动 ~700ms）、oh-my-posh 的 notice/upgrade 联网自检（~1.6s→83ms）、PATH 非幂等追加导致的旧版二进制遮蔽新版。含分段计时 / 交替 A/B 取中位数 / 惰性化验证 / 干净环境对比的通用方法论，以及一个进程内 ~2ms 的 powerlevel10k 复刻 prompt 作为 spawn 的替代品，另有 7 个常见坏函数速修表。Trigger: /pwshfix, pwsh启动慢, PowerShell启动卡, profile加载慢, 终端打开慢'
trigger: /pwshfix
---

# PowerShell Startup Hang Fix

使用场景：**打开 pwsh / Windows Terminal 时明显卡顿**（profile 加载数百毫秒到数秒），或每次开终端都刷重复输出。

适用平台：**Windows + PowerShell 7.x (pwsh)**。第 5 节方法论可迁移到任何"启动慢"场景；姊妹技能 `shell-startup-hang-fix` 覆盖 macOS + zsh。

核心原则：**先量，再猜。**

- **恒定慢** → 通常是某段代码每次必执行（如大模块同步导入）
- **随网络波动** → 通常是联网自检 / 超时重试
- **版本不对、行为诡异** → 往往是 PATH 里藏着两个同名二进制

三类根因的修法完全不同，别混着猜。

---

## 0. 三类根因速判表

| 类型 | 典型症状 | 一句话根因 | 关键验证 |
|---|---|---|---|
| **A. 大模块同步导入** | 启动固定慢 ~0.7s，耗时集中在某次 `Import-Module` | 模块加载时全量解析脚本 + 每次写盘缓存 | `Measure-Command { Import-Module Terminal-Icons }` |
| **B. 联网自检** | 启动慢且**波动大**（0.4~1.6s），断网反而更快 | 工具初始化时检查公告 / 更新，卡在网络往返 | 单测 `oh-my-posh init pwsh`；`oh-my-posh disable notice,upgrade` |
| **C. PATH 重复 / 遮蔽** | `xxx --version` 不是你以为的版本；行为随 shell 嵌套变化 | PATH 被反复追加（非幂等），旧版在尾部 / 更前目录胜出 | `Get-Command <cmd> -All` |

> A 与 C 常同时出现。本机就是先修 A，再发现 C 让 `oh-my-posh` 解析到了旧版（v25 而非 v29）。

---

## 1. 现场诊断（按序执行，只读）

```powershell
# 1. 量总时长：干净基线 vs 带 profile
Measure-Command { pwsh -NoProfile -Command 'exit' } | % TotalMilliseconds   # 基线（本机 ~120ms）
Measure-Command { pwsh            -Command 'exit' } | % TotalMilliseconds   # 带 profile

# 2. 逐个计时可疑项（把"猜"换成"数"）
Measure-Command { Import-Module Terminal-Icons }    | % TotalMilliseconds
Measure-Command { oh-my-posh init pwsh | Out-Null } | % TotalMilliseconds

# 3. 版本 / 路径是否唯一
Get-Command oh-my-posh -All | Select -Expand Source
(Get-Module).Count          # 干净 shell 应为 0；profile 加载后每多一个模块都问一句"值不值"

# 4. PATH 是否有重复项（出现在 >1 次即非幂等追加在作祟）
($env:Path -split ';' | Group-Object | ? Count -gt 1 | % { "{0} x{1}" -f $_.Name, $_.Count })
```

**排除项**（实测已否证，别重复走）：与磁盘速度无关；与 `$PROFILE` 体积无关（解析 900 行 < 10ms）；与杀软实时扫描无关。

---

## 2. 根因 A：大型模块在启动时同步导入 → 固定 ~700ms

### 症状
启动固定慢 ~0.7s，且 `Measure-Command { Import-Module <X> }` 能**独立复现**同一量级。

### 机制（以 Terminal-Icons 为例）
1. 模块体执行时解析 **~780 KB** PowerShell（`Terminal-Icons.psm1` 206 KB + `Data/glyphs.ps1` 571 KB，**9253** 条字形）→ 本机实测 **~705ms**。
2. 它还在**每次加载**时用 `Export-Clixml` 重写 **~180 KB** 主题 XML 到磁盘 —— 纯缓存写入，与图标是否正确无关。
3. 关键：慢的是**模块体执行**，不是文件读取。所以"磁盘快"救不了它。

### 修复：惰性导入 —— 首次用到时才加载

不要 `Import-Module Terminal-Icons` 放在 profile 顶部，而是**影子**核心 cmdlet，首次列目录时再导入：

```powershell
$script:TerminalIconsLoaded = $false
function global:Get-ChildItem {
    if (-not $script:TerminalIconsLoaded) {
        $script:TerminalIconsLoaded = $true
        Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    }
    Microsoft.PowerShell.Management\Get-ChildItem @args   # 必须模块限定名
}
```

**要点**
- 用**模块限定名** `Microsoft.PowerShell.Management\Get-ChildItem` 调回真实 cmdlet；直接写 `Get-ChildItem` 会**递归调用自己**，直接把 shell 玩死。
- 影子 `Get-ChildItem` 让所有别名（`ls` / `dir` / `gci` / `ll`）一并受益 —— 它们最终都解析到它。
- 用 `$script:` 作用域标记，避免污染全局。

### 验证「惰性真的生效」
```powershell
pwsh -Command '(Get-Module).Count; ls > $null; (Get-Module).Count'
# 期望 0 → 1：启动时不加载，首次 ls 才加载
```

---

## 3. 根因 B：oh-my-posh 的 notice / upgrade 联网自检

### 症状
- 启动耗时**波动大**（本机 0.4~1.6s），代理不通或断网时更明显。
- `Measure-Command { oh-my-posh init pwsh }` 单独就吃掉大部分启动时间。

### 机制
`oh-my-posh init` 会顺带做**公告检查 + 升级自检**（每个新 shell 一次），网络往返直接叠加在启动路径上。本机实测 **1618ms → 83ms**（关闭后）。

### 修复
```powershell
oh-my-posh disable notice     # 关闭版本公告
oh-my-posh disable upgrade    # 关闭升级自检
```
写入 omp 自身配置后，后续 `init` 不再联网。**这是收益 / 风险比最高的一步：完全不改任何显示效果。**

### 附：为什么没走「精简主题」这条路
profiling 显示：渲染一次 90ms 里 **~75ms 是进程启动本身**（`oh-my-posh.exe` 每次回车都要 spawn），精简段最多省 ~15ms。所以正解不是瘦身主题，而是 ① 关联网自检；② 见第 4 节，干脆用**进程内 prompt** 替掉 spawn。
---

## 4. 根因 C：PATH 非幂等追加 → 旧版二进制遮蔽新版

### 症状
- `oh-my-posh --version` 是**旧版**（本机 v25.16.1，来自 `Program Files (x86)` 的 MSI），而你装在 `C:\tools` 的是 v29.15.1。
- 嵌套 shell 里 PATH 越来越长。

### 机制
```powershell
# ❌ 非幂等：每次 pwsh 套 pwsh 都追加一次，且追加到【尾部】
$env:Path += ";C:\tools"
```
两重问题：
1. **重复膨胀** —— 每层嵌套 +1，无界增长。
2. **排在尾部** —— 若系统里另有同名 exe 在更靠前的目录（如 MSI 装的旧版），**旧版胜出**。

### 修复：幂等归一 —— 去重 + 前置
```powershell
$pathParts = @($env:Path -split ';' | Where-Object { $_ -and $_ -ne 'C:\tools' })
$env:Path = (@('C:\tools') + $pathParts) -join ';'
```
- 先剔除**所有** `C:\tools` 副本，再在最前面加回**恰好一个**。
- **幂等**：重复 source profile、嵌套 shell 都不再膨胀。
- **前置**：确保你的新版赢过系统里的旧版。

**同时**建议卸载残留的旧版 MSI，从根上消除遮蔽（本机 GUID）：
```powershell
$p = Start-Process msiexec -ArgumentList '/x','{D7BE99D2-A374-4F31-BDDF-79055FC7B36C}','/qn','/norestart' `
                          -Verb RunAs -Wait -PassThru
$p.ExitCode    # 0=成功  1605=该产品未安装
```

### 验证
```powershell
Get-Command oh-my-posh -All | Select -Expand Source    # 只应剩 C:\tools\oh-my-posh.exe
oh-my-posh --version                                    # 应为新版
($env:Path -split ';' | ? { $_ -eq 'C:\tools' }).Count  # 必须 == 1
```

---

## 5. 通用排查方法论（可迁移到任何"启动慢"）

```text
1. 先量总量            干净基线 (pwsh -NoProfile) vs 带 profile
   └ 恒定 → 怀疑"每次必执行的一段代码"；波动 → 怀疑联网 / 超时

2. 分段 / 逐项计时     Measure-Command { Import-Module X } / { tool init ... }
   └ 把"猜"换成"数"，一次锁定量级

3. 交替 A/B 取中位数   ⚠️ 关键坑：机器有负载时 Measure-Command 的【均值】会失真
   └ 正确做法：old→new→old→new 交替测，各取【中位数】
   └ 千万别用"跑一次旧的、跑一次新的"来对比

4. 惰性化验证          改完量"启动模块数=0 → 首次 ls 后=1"，证明真的没提前加载

5. 干净环境对比        pwsh -NoProfile 排除"父 shell 注入的环境"
   └ 区分「profile 本身的问题」vs「从父进程继承来的污染」—— 最关键的一步

6. 二分定位            注释掉 profile 的后半段，逐步缩小范围
   └ 注意别切断续行 / 多行结构

7. 证据链闭合          颜色取字节、宽度取实测、文件取 md5，不靠"看着差不多"
```

**为什么第 3 步关键**：本机在模拟高负载下，「跑一次旧的、跑一次新的」给出的是**互相矛盾**的结论；改成交替 A/B 并取中位数后，才稳定复现 ~700ms 的模块开销。

**为什么第 5 步关键**：PATH 遮蔽类问题（根因 C）在「继承父环境」和「干净环境」下**看到的是两个不同结论**，只看单条链会误判成"本来就这样"。

---

## 6. 附带交付：进程内原生 prompt（可选，替代每次回车 spawn 进程）

`oh-my-posh` 每按一次回车都 spawn 一个 `oh-my-posh.exe`（~90ms）。若想保留 powerlevel10k 的**外观**、去掉进程开销，可在 profile 里实现一个**纯 PowerShell** 复刻版：

- **调色板 / 段完全对齐** omp 主题 `powerlevel10k_rainbow.omp.json`：
  OS `#d3d7cf`、path `#3465a4` / 文字 `#e4e4e4`、干净 git `#4e9a06`、脏 git `#c4a000`、状态 `#000000`（失败 `#cc2222`）、时间 `#d3d7cf`；powerline 分隔符 `\uE0B0` / `\uE0B2`。
- **分支不 spawn git**：直接读 `.git/HEAD`（~2ms）。脏计数仍需 `git status`，但**按 TTL 缓存**（本机大仓库一次 `git status` ~130ms，不能每次回车都跑）。
- **第 2 行的 `─╯` 用 ESC7 / ESC8**（保存 / 恢复光标）绘制，**不移动真实光标**，保证最后一行仍是干净的 `╰─ `，PSReadLine 行编辑不受影响；并配合 `Set-PSReadLineOption -ExtraPromptLineCount 1`。
- **CJK 宽度**：中文字符计 **2 列**，否则右对齐会错位。

### 可切换引擎（便于随时回退）
```powershell
if (-not $PromptEngine) { $PromptEngine = 'native' }   # 环境里已有值则不覆盖 → 支持运行时切换
```
```powershell
$PromptEngine='omp';    . $PROFILE   # 切回 oh-my-posh
$PromptEngine='native'; . $PROFILE   # 切回原生（快）
```

> ⚠️ **不要**写 `Set-Alias prompt Get-Prompt`。PowerShell 命令名**不区分大小写**，别名会遮蔽同名函数；`prompt` 上的别名与函数互相遮蔽，直接搞坏 prompt。同理 `Set-Alias grep Grep` 是**自指遮蔽**，会把 `grep` 和 `Grep` **一起**弄坏 —— 函数本身已能同时响应两种拼写，无需别名。

---

## 7. 顺手修掉的坏函数（同一 profile 里的常见雷）

| 现象 | 根因 | 修法 |
|---|---|---|
| `Grep "x" .\src` 第二个参数不生效 | 参数缺 `Position` | `[Parameter(Position=1)]$Path` |
| `GrepR` 必报错 | 给 `Select-String` 传了它没有的 `-Recurse` | `Get-ChildItem -Path $Path -Include $Include -Recurse -File \| Select-String ...` |
| PS7 上 `Test-Connection` 统计全 0 | PS7 用 `.Latency`（旧版是 `.RoundtripTime`） | 读 `.Latency`；单样本不算标准差 |
| `Split-Path -LiteralPath X -Parent` 报参数集冲突 | `LiteralPathSet` 无 `-Parent` | `[IO.Path]::GetDirectoryName($X)` |
| `[Console]::WindowWidth` 报"句柄无效" | 无控制台句柄时不可用 | `$Host.UI.RawUI.WindowSize.Width` |
| `Get-SystemInfo` 除零 | 0 容量挂载点参与百分比计算 | 过滤 `Used + Free -gt 0` |
| git 报 unknown revision | 把哈希表当字面量传给了 git | 传字符串 `HEAD...origin/HEAD` |

---

## 8. 验证闭环（改完必跑）

```powershell
# 1. 启动耗时（交替 A/B 取中位数，别只看一次）
$old = 1..5 | % { (Measure-Command { pwsh -NoProfile -Command 'exit' }).TotalMilliseconds }
$new = 1..5 | % { (Measure-Command { pwsh            -Command 'exit' }).TotalMilliseconds }
"profile 净开销 ≈ {0}ms" -f ([int](($new | Sort-Object)[2]) - [int](($old | Sort-Object)[2]))

# 2. 惰性生效：启动 0 模块 → 首次 ls 后 1 模块
pwsh -Command '(Get-Module).Count; ls > $null; (Get-Module).Count'

# 3. PATH 无重复、解析唯一
pwsh -Command '($env:Path -split ";" | Group-Object | ? Count -gt 1).Count; (Get-Command oh-my-posh -All).Source'

# 4. 联网自检已关：init 应稳定 < 200ms 且不再大幅波动
1..3 | % { "{0}ms" -f [int](Measure-Command { oh-my-posh init pwsh | Out-Null }).TotalMilliseconds }

# 5. 工具函数自检（本机 16/16 通过）
pwsh -Command 'Get-NetworkStatus; Test-Port 127.0.0.1 445; Get-SystemInfo; Get-PingStats 127.0.0.1 -Count 2'
```

### 验收口径（本机 2026-09-24，Windows + pwsh 7.6.6 实测基线）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| profile 启动耗时 | **1083ms** | **~250-350ms** |
| Terminal-Icons 启动开销 | **~705ms**（每次启动） | **0**（首次 `ls` 才加载） |
| `oh-my-posh init` | **1618ms**（联网自检） | **~83ms** |
| 每次回车 prompt 开销 | ~90ms（spawn `oh-my-posh.exe`） | **~2-23ms**（进程内原生） |
| 启动时模块数 | 1+（含 Terminal-Icons） | **0** |
| PATH 中 `C:\tools` 副本数 | 每次嵌套 +1（无界增长） | **恒为 1** |
| `oh-my-posh --version` | v25.16.1（旧版遮蔽） | **v29.15.1** |

**最后一步：让用户开一个新终端**（或 `. $PROFILE`），清掉旧 shell 里已膨胀的 PATH 与已加载的模块。旧 shell 不会自动变干净。

---

## 9. 变更留痕清单

每次改动都应留下：
- 备份：`Copy-Item $PROFILE "$PROFILE.bak.$(Get-Date -f yyyyMMdd_HHmmss)"`（本机 16052 字节原文）
- 卸载旧版 MSI 走 `msiexec /x ... /qn /norestart`（幂等；`1605` 表示该产品已不在）
- 记录到 memory：`pwsh-startup-terminal-icons-lazy-load` / `pwsh-omp-notice-upgrade-network-check` / `pwsh-path-duplicate-shadowing`