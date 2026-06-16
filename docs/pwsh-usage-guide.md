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

### 文件搜索

#### Grep — 文件内容搜索
```powershell
Grep "TODO" .\src -Include *.py

Grep "error" *.log -IgnoreCase
```

#### GrepR / gr — 递归搜索
```powershell
GrepR "function" .\src -Include *.ps1

gr "error" .\logs
```

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

---

## 快速参考卡片

### 最常用命令
```
. $PROFILE       重新加载 profile
Get-Prompt       查看所有函数/别名
gs               Git status
Gc "msg"         Git commit
pro/obs/pub      目录跳转
Get-NetworkStatus 网络诊断
Test-Port        端口检测
Top-Processes    进程排名
Get-SystemInfo   系统信息
```

### 最常用别名
```
ls             Get-ChildItem
cat            Get-Content
grep/gr        Select-String
gs             Get-GitStatus
vi/vim         code (VS Code)
```

---

*Created by Ant Rich — PowerShell 7.6+*
