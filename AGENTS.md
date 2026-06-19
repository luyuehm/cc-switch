# cc-switch — AGENTS.md

## 这是什么

**macOS (bash/zsh) 端 Claude Code 模型切换器 + CPA 代理同步 + 技能菜单管理工具。**

此仓库是**提供安装内容**，而非可运行的应用程序。用户运行 `install.sh` 后，实际运行位置在 `~/.claude/cc-switch.sh`（通过 `~/.zshrc` source）。

## 核心架构

- **`cc-switch.sh`** — 唯一主脚本。定义所有 `cc*` shell 函数。读取/写入 `~/.claude/settings.json`（Claude Code 配置）。
- **`install.sh`** — 复制 `cc-switch.sh` 到 `~/.claude/`，追加到 `.zshrc`，可选安装 oh-my-posh/zoxide。
- **`switch.md`** — 放置于 `~/.claude/commands/switch.md` 的斜杠命令技能。注意：包含 Windows 路径 (`C:\Users\...`) — 这些内容已过时，在 macOS 上请忽略。
- **`skills/cc-menu/`** — 含 `SKILL.md`、`cc-menu.sh` 及 CPA 清理 Python 脚本的 Claude Code 技能。

## 构建 / 测试

**无**构建步骤、包管理器、锁文件、测试框架或 CI。仅为 shell 脚本。编辑后无需运行任何命令。

## 关键命令

所有命令均为 `~/.claude/cc-switch.sh` 中的 shell 函数：

| 命令 | 作用 |
|-------|------|
| `cc` | 显示模型菜单 |
| `cc <model>` | 切换模型并以 `--bare` 模式启动 Claude Code |
| `cc-pro` / `cc-fast` / `cc-default` | 特定模型快捷方式 |
| `cc-status` | 显示当前模型及完整清单 |
| `cc-sync [--list --force --remove]` | 从 CPA 代理获取/对比/新增/删除模型 |
| `cc-audit` | 技能可见性审计报告 |
| `cc-hide <skill>` / `cc-show <skill>` | 隐藏/恢复技能 |
| `cc-profile {default\|minimal\|dev}` | 技能可见性预设 |
| `cc-commands {list\|create\|remove}` | 管理自定义斜杠命令 |
| `cc-theme [name]` | 列出/切换 Oh My Posh 主题 |

## 环境 / 密钥

- 密钥存储于 **`~/.claude/cc-switch.env`**（而非仓库中的 `.env`）。
- 向 `.env.example` 添加新变量时，同时更新 `__cc_load_env`（在 `cc-switch.sh` 中读取密钥）。
- 仓库中的 `*.env` 被 gitignore 忽略（仅 `.env.example` 可被追踪）。

## 需要留意的细节

- 模型切换时会在 `settings.json` 中写入约 **10 个字段**（`env.ANTHROPIC_MODEL`、`fallbackModel`、`model` 等）。执行相同操作时需全部设置。
- `cc <model>` 在切换后始终调用 Claude Code (`claude --bare`)。如只需切换而不启动，请编辑 `settings.json`。
- CPA 同步通过 `curl` 调用，会发送 `Authorization: Bearer` 标头 — 若添加新端点，请保持此模式。
- 无 linter/formatter 配置。脚本使用 `python3` 进行 JSON 处理 — 请勿添加 `jq` 依赖。
