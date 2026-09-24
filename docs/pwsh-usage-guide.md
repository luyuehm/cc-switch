# PowerShell 使用手册

## 目录
- [基础概念](#基础概念)
- [实用函数](#实用函数)
- [Git 快捷](#git-快捷)
- [文件搜索](#文件搜索)
- [网络工具](#网络工具)
- [系统监控](#系统监控)
- [目录跳转](#目录跳转)
- [核心语法](#核心语法)
- [快捷键](#快捷键)
- [自定义](#自定义)
- [Prompt 引擎与启动优化](#prompt-引擎与启动优化)
- [已修复的问题](#已修复的问题)

---

## 基础概念

### 管道传递的是对象，不是字符串
```powershell
# Linux: 字符串 → 管道 → 字符串
ps aux | grep python | awk '{print $2}'

# PowerShell: 对象 → 管道 → 操作属性
Get-Process | Where-Object CPU -gt 100 | Select-Object Name, CPU, WorkingSet
```

### Tab 补全
```
Tab         # 补全命令、文件名、参数
Tab 多次    # 循环选择多个匹配项
Ctrl+T      # 按类型补全（文件/命令/变量）
```

### 管道速记
```powershell
?           # Where-Object
select      # Select-Object
%           # ForEach-Object
% { ... }   # ForEach-Object 块
```

### 变量展开
```powershell
$name = "world"
Write-Host "hello $name"        # hello world  （双引号，展开变量）
Write-Host 'hello $name'       # hello $name  （单引号，不展开）
```

### Here-string（多行字符串）
```powershell
# 不展开变量
$script = @'
function hello {
    Write-Host "hello"
}
'@

# 展开变量
$dir = "D:\projects"
$log = @"
Working in $dir
Files: $(Get-ChildItem $dir).Count
"@
```

---

## 实用函数

### 网络工具

#### Get-NetworkStatus — 网络诊断
```powershell
Get-NetworkStatus
# 默认检测 google.com

Get-NetworkStatus baidu.com
# 指定目标
```
输出：Ping 状态、延迟（avg/min/max）、DNS 解析、Traceroute

#### Test-Port — 端口检测
```powershell
Test-Port google.com -Ports @(80, 443, 8080)

Test-Port localhost 3306
```
输出：OPEN / CLOSED

#### Get-PingStats — 持续 Ping
```powershell
Get-PingStats google.com -Count 50 -Interval 1
```
输出：实时进度、成功率、丢包率、抖动（jitter）

> PowerShell 7 用 `PingReply.Latency` 取延迟（Windows PowerShell 5.1 是 `.RoundtripTime`）；
> 单次采样不会计算标准差（`jitter` 显示为 `-`）。

### 文件搜索

#### Grep — 文件内容搜索
```powershell
Grep "TODO" .\src -Include *.py

Grep "error" .\logs -Include *.log
```
输出：`文件名:行号: 该行内容`。`$Path` 位于位置 1，可省略（默认 `.`）。

> `-IgnoreCase` 是兼容参数，实际不生效——`Select-String` 默认就**不区分大小写**。

#### GrepR / gr — 递归搜索
```powershell
GrepR "function" .\src -Include *.ps1

gr "error" .\logs
```
递归由 `Get-ChildItem -Recurse -File` 提供（`Select-String` 本身没有 `-Recurse`）。

#### Get-FileSizeSummary — 目录大小
```powershell
Get-FileSizeSummary .\Downloads

Get-FileSizeSummary -Depth 3
```
输出：文件夹数、文件数、总大小

### Git 快捷

#### Get-GitStatus / gs — 仓库状态
```powershell
Get-GitStatus
gs
```
输出：分支、Ahead/Behind、最近 3 次提交

#### Gc — 快速提交
```powershell
Gc "fix: resolve crash on null"
```
自动 git add . + git commit -m

### 系统监控

#### Top-Processes — 进程排名
```powershell
Top-Processes -Top 10 -By CPU
Top-Processes -Top 15 -By Memory
```
输出：按 CPU 或内存排序的 Top N 进程

#### Get-SystemInfo — 系统信息
```powershell
Get-SystemInfo
```
输出：OS、PowerShell 版本、RAM、CPU、磁盘使用率

---

## 核心语法

### Where-Object（过滤）
```powershell
Get-Process | Where-Object CPU -gt 100
Get-Process | ? CPU -gt 100

# 复杂条件
Get-Process | ? { $_.WorkingSet -gt 100MB -and $_.CPU -gt 50 }

# 按名称匹配
Get-Process | ? Name -like "*chrome*"
```

### Select-Object（选列）
```powershell
# 选列
Get-Process | Select-Object Name, CPU, WorkingSet -First 10

# 计算属性
Get-Process | Select-Object Name, @{
    Name = 'MemMB'
    Expression = { [math]::Round($_.WorkingSet / 1MB, 1) }
}

# 去重
Get-Process | Select-Object Name -Unique
```

### ForEach-Object（循环）
```powershell
# 简单表达式
1..10 | % { $_ * 2 }

# 多行块
Get-ChildItem -File | % {
    $sizeMB = [math]::Round($_.Length / 1MB, 2)
    Write-Host "$($_.Name)`t$sizeMB MB"
}
```

### 管道传递
```powershell
# 管道传递当前对象（$_）
Get-Process | Where-Object { $_.WorkingSet -gt 1GB }

# 管道传递数组
1..100 | ? { $_ % 7 -eq 0 }
```

### 数组和范围
```powershell
# 创建数组
@(1, 2, 3, 4, 5)

# 范围
1..10          # [1,2,3,4,5,6,7,8,9,10]
10..1          # [10,9,8,7,6,5,4,3,2,1]

# 过滤
@(1,2,3,4,5) | ? { $_ -gt 3 }
```

---

## Git 快捷

### 常用 Git命令
```powershell
# 查看状态
gs

# 提交
Gc "feat: add new feature"

# 更多（原生命令）
git log --oneline -10
git status -sb
git diff HEAD~3
git stash list
git branch -a
```

### Git 别名
```powershell
# 建议加到 profile
Set-Alias gl 'git log --oneline --graph --decorate -20'
Set-Alias gp 'git push'
Set-Alias gg 'git pull'
Set-Alias gst 'git status'
Set-Alias gco 'git checkout'
Set-Alias gcb 'git branch'
```

---

## 网络工具

### DNS 查询
```powershell
[System.Net.Dns]::GetHostEntry("google.com")

# 或者
Resolve-DnsName google.com
```

### HTTP 请求
```powershell
# GET
$response = Invoke-WebRequest -Uri "https://api.github.com/repos/luyuehm/cc-switch"
$data = $response.Content | ConvertFrom-Json
$data.stargazers_count

# POST
Invoke-WebRequest -Uri "https://api.example.com/data" `
    -Method POST `
    -ContentType "application/json" `
    -Body '{"key":"value"}'

# 带认证
$headers = @{ "Authorization" = "Bearer sk-xxx" }
Invoke-WebRequest -Uri "https://api.example.com/data" -Headers $headers
```

### 下载/上传
```powershell
# 下载
Invoke-WebRequest -Uri "https://example.com/file.zip" -OutFile "file.zip"

# 上传（curl 方式）
curl -X POST -F "file=@data.csv" https://upload.example.com
```

---

## 系统监控

### 进程管理
```powershell
# 列出所有进程
Get-Process

# 按名称搜索
Get-Process -Name chrome
Get-Process chrome   # 简写

# 停止进程
Stop-Process -Name chrome -Force

# Top-Processes（自定义函数）
Top-Processes -Top 10 -By Memory
```

### 服务管理
```powershell
Get-Service | Where-Object Status -eq "Running"
Get-Service | ? Status -eq "Stopped" | ? Name -like "*sql*"
Stop-Service -Name Spooler
Start-Service -Name Spooler
```

### 磁盘信息
```powershell
Get-PSDrive -PSProvider FileSystem
Get-Volume
Get-CimInstance Win32_LogicalDisk
```

---

## 目录跳转

### zoxide（智能跳转）
```powershell
cd D:\projects\cc-switch
# zoxide 自动学习你常用的目录

z pro        # 跳转到 projects（自动匹配）
z code       # 跳转到 vscode 目录
z obs        # 跳转到 obsidian-vault

zi pro       # 交互式选择
```

### 自定义别名
```powershell
# 在 profile 中定义
Set-Alias pro '/mnt/d/vscode'         # 项目目录
Set-Alias obs '/mnt/d/obsidian-vault' # Obsidian vault
Set-Alias pub '/mnt/d/prometheus_report_cache'
```

### 快速回退
```powershell
cd ..        # 上一级
cd /         # 根目录
cd -         # 上一个目录（像 bash）
```

---

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| Tab | 补全命令/文件/参数 |
| ↑/↓ | 搜索命令历史 |
| Ctrl+R | 反向搜索历史 |
| Ctrl+U | 清除当前行 |
| Ctrl+L | 清屏 |
| Esc | 退出/确认选择 |
| Ctrl+C | 中断当前命令 |
| Ctrl+Shift+N | 新窗口 |
| F2 | 编辑当前行 |
| F8 | 搜索历史命令（完全匹配） |

---

## 自定义

### 添加函数到 profile
```powershell
# 打开 profile 文件
notepad $PROFILE

# 或者
code $PROFILE
```

### 添加函数示例
```powershell
function MyFunc {
    param([string]$Arg = "default")
    Write-Host "Hello $Arg!" -ForegroundColor Green
}

# 添加别名
Set-Alias mf MyFunc
```

### 添加颜色
```powershell
# 启用语法高亮
Set-PSReadLineOption -Colors @{
    Command = 'Cyan'
    Parameter = 'Yellow'
    String = 'Green'
    Number = 'Magenta'
    Type = 'Blue'
}

# 启用预测建议
Set-PSReadLineOption -PredictionSource History
```

### 检查环境变量
```powershell
$env:PATH                    # 查看 PATH
$env:USERPROFILE             # 用户目录
$env:TEMP                    # 临时目录
$PROFILE                     # PowerShell profile 路径
```

---

## Prompt 引擎与启动优化

`profile-backup.ps1` 内置两种 prompt 引擎，可用变量随时切换：

| 引擎 | 渲染方式 | 每次回车开销 | 说明 |
|------|----------|--------------|------|
| `native`（默认） | 纯 PowerShell，进程内 | ~2–23 ms | 复刻 `powerlevel10k_rainbow` 外观 |
| `omp` | 每次 spawn `oh-my-posh.exe` | ~90 ms | 主题丰富，可换任意主题 |

```powershell
$PromptEngine='omp';    . $PROFILE   # 切到 oh-my-posh
$PromptEngine='native'; . $PROFILE   # 切回原生（快）
Get-Prompt                            # 查看当前引擎（别名 pwsh-help）
```

> 变量只在「未设置」时取默认值（`if (-not $PromptEngine)`），所以重新 source profile
> 不会覆盖你在运行时做的切换。

### native 引擎渲染效果

```
╭─   D:\repo  main ✔      1.2s   ✔   15:04:05      ─╮
╰─
```

- 段与配色逐字节对齐 `powerlevel10k_rainbow.omp.json`：OS `#d3d7cf`、路径 `#3465a4` / 文字 `#e4e4e4`、干净 git `#4e9a06`、脏 git `#c4a000`、执行耗时 `#c4a000`、状态 `#000000`（失败 `#cc2222`）、时间 `#d3d7cf`。
- 分支直接读 `.git/HEAD`（~2 ms），**不 spawn git**；脏计数需要 `git status`，但**按 TTL 缓存**（默认 2 秒），因为大仓库跑一次 `git status` 约 130 ms。
- 第 2 行的 `─╯` 用 ESC7 / ESC8（保存 / 恢复光标）绘制，**不移动真实光标**，最后一行仍是干净的 `╰─ `，PSReadLine 行编辑不受影响（配合 `Set-PSReadLineOption -ExtraPromptLineCount 1`）。
- 中文按 **2 列**计算宽度，右对齐不会错位。

### 可调参数（native 引擎）

```powershell
$script:GitStatusMode = 'cached'   # 'off' | 'cached' | 'always'
$script:GitStatusTtl  = 2.0        # git status 刷新间隔（秒）
$script:ExecTimeMinMs = 500        # 执行耗时低于此值不显示
$script:ShowGitStash  = $true      # 是否显示 stash 数
```

### 启动优化

| 优化 | 手段 | 效果 |
|------|------|------|
| Terminal-Icons 惰性加载 | 影子 `Get-ChildItem`，首次列目录才 `Import-Module` | 省 ~705 ms |
| 关闭 omp 联网自检 | `oh-my-posh disable notice` + `disable upgrade` | `init` 1618 ms → 83 ms |
| PATH 幂等归一 | 去重 + 前置 `C:\tools` | 消除无界增长与旧版遮蔽 |

```powershell
# 验证惰性加载：启动时 0 个模块，首次 ls 后 1 个
(Get-Module).Count; ls > $null; (Get-Module).Count
```

---

## 已修复的问题

以下问题在 profile 中已修复，列在这里便于回溯。完整排查方法论见
[`skills/pwsh-startup-hang-fix/SKILL.md`](../skills/pwsh-startup-hang-fix/SKILL.md)。

| 现象 | 根因 | 修法 |
|------|------|------|
| `grep` 和 `Grep` 一起失效 | `Set-Alias grep Grep` 是自指遮蔽（命令名不区分大小写） | 删掉别名；函数本身响应两种拼写 |
| `Grep "x" .\src` 第二个参数不生效 | `$Path` 缺 `Position` | `[Parameter(Position=1)]` |
| `GrepR` 必报错 | 给 `Select-String` 传了它没有的 `-Recurse` | 改为 `Get-ChildItem -Recurse -File \| Select-String` |
| PS7 上 `Get-PingStats` 延迟全为 0 | PS7 用 `.Latency`（`.RoundtripTime` 是旧版名字） | 读 `.Latency`；单样本不算标准差 |
| `Split-Path -LiteralPath X -Parent` 报参数集冲突 | `LiteralPathSet` 没有 `-Parent` | `[IO.Path]::GetDirectoryName()` |
| `[Console]::WindowWidth` 报「句柄无效」 | 无控制台句柄时不可用 | `$Host.UI.RawUI.WindowSize.Width` |
| `Get-SystemInfo` 除零 | 0 容量挂载点参与了百分比计算 | 过滤 `Used + Free -gt 0` |
| `ll` / `lsa` 报错 | `Set-Alias ll 'Get-ChildItem -Force'`——别名不能带参数 | 改为函数 |
| `prompt` 被搞坏 | `Set-Alias prompt Get-Prompt`——`prompt` 是保留函数名 | 删除别名 |
| 嵌套 shell 里 PATH 无界增长 | `$env:Path += ";C:\tools"` 非幂等 | 去重 + 前置 |
| git 报 `unknown revision` | 把哈希表当字面量传给了 git | 传字符串 `HEAD...origin/HEAD` |

### 修复前后基线（Windows + PowerShell 7.6.6）

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| profile 启动耗时 | 1083 ms | ~250–350 ms |
| Terminal-Icons 启动开销 | ~705 ms | 0（首次 `ls` 才加载） |
| `oh-my-posh init` | 1618 ms | ~83 ms |
| 每次回车 prompt 开销 | ~90 ms | ~2–23 ms |
| 启动时模块数 | 1+ | 0 |
| PATH 中 `C:\tools` 份数 | 无界增长 | 恒为 1 |
| `oh-my-posh --version` | v25.16.1（被旧版遮蔽） | v29.15.1 |

---

## 常见问题

### Q: 如何列出所有函数？
```powershell
Get-Command -CommandType Function
Get-Command | Where-Object { $_. CommandType -eq "Function" }
```

### Q: 如何查看函数定义？
```powershell
Get-Content ($PROFILE)   # 查看整个 profile
select-string -Path $PROFILE "function MyFunc"  # 搜索特定函数
```

### Q: 如何调试？
```powershell
Write-Host "debug: $variable" -ForegroundColor Yellow
Get-Variable | Where-Object Name -like "*my*"
Get-Location
Get-ChildItem -Force
```

### Q: 如何查看命令帮助？
```powershell
Get-Help Get-Process
Get-Help Get-Process -Examples

# 在线帮助
Get-Help Get-Process -Online
```

### Q: 如何查看所有别名？
```powershell
Get-Alias
Get-Alias | Where-Object Name -like "g*"
```

### Q: 终端启动慢 / 想换 prompt 风格？
```powershell
# 先量，再猜：逐个测可疑项的独立开销
Measure-Command { Import-Module Terminal-Icons }    | % TotalMilliseconds
Measure-Command { oh-my-posh init pwsh | Out-Null } | % TotalMilliseconds

# 切换 prompt 引擎
$PromptEngine='omp';    . $PROFILE   # 丰富（oh-my-posh 主题）
$PromptEngine='native'; . $PROFILE   # 快（内置 prompt）
```
> 注意：机器有负载时 `Measure-Command` 的**均值会失真**，应交替测新旧并取**中位数**。
> 完整排查步骤见 [`docs` 的「Prompt 引擎与启动优化」](#prompt-引擎与启动优化) 与 `/pwshfix` 技能。

---

## 快速参考卡片

### 最常用命令
```
. $PROFILE       重新加载 profile
Get-Prompt       查看所有函数/别名（别名 pwsh-help）
gs               Git status
Gc "msg"         Git commit
pro/obs/pub      目录跳转
Get-NetworkStatus 网络诊断
Test-Port        端口检测
Top-Processes    进程排名
Get-SystemInfo   系统信息
$PromptEngine='omp'; . $PROFILE   切换 prompt 引擎
```

### 最常用别名
```
ls             Get-ChildItem
cat            Get-Content
grep           Grep（函数，包装 Select-String）
gr             GrepR（递归搜索）
gs             Get-GitStatus
vi/vim         code (VS Code)
pwsh-help      Get-Prompt（函数/别名菜单）
```

---

*Created by Ant Rich — PowerShell 7.6+*
