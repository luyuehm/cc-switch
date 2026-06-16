---
name: cc-menu
description: Claude Code 斜杠命令菜单管理 — audit, organize, hide/show skills and custom commands
author: luyuehm
trigger: "/cc-menu"
user-invocable: true
effort: low
---

# cc-menu — Claude Code 菜单管理

管理 Claude Code 的 `/` 斜杠命令菜单：审计可见技能、隐藏/显示技能、管理自定义斜杠命令。

**共享 CLI 脚本:** `~/.claude/skills/cc-menu/bin/cc-menu.sh`
**GitHub:** https://github.com/luyuehm/cc-menu

## 快速使用

在对话中输入 `/cc-menu` 进入菜单管理模式，再选择要执行的操作。

或者直接使用 CLI 脚本:
```bash
~/.claude/skills/cc-menu/bin/cc-menu.sh audit
~/.claude/skills/cc-menu/bin/cc-menu.sh hide document-skills:*
```

## 目录结构

```bash
~/.claude/
  commands/            # 自定义斜杠命令 (markdown 文件)
    switch.md
    models.md
  skills/cc-menu/      # 本 skill
    SKILL.md           # 技能定义
    bin/
      cc-menu.sh       # 共享 CLI 脚本 (Claude Code + OpenClaw 共用)
      proxy_cpa_cleaner.py       # (可选) 本地多线程消息清洗中间件
      test_and_register_models.py # (可选) 自动发现与模型可用性测试脚本
  settings.json        # skillOverrides 控制菜单可见性
```

## CLI 脚本用法

```bash
# 审计
cc-menu.sh audit

# 控制可见性
cc-menu.sh hide docx                        # 隐藏单个技能
cc-menu.sh hide document-skills:*           # 隐藏整个插件
cc-menu.sh show docx                        # 恢复显示

# 管理自定义命令
cc-menu.sh command create my-cmd "描述" "参数提示"
cc-menu.sh command remove my-cmd
cc-menu.sh command list

# 预设配置
cc-menu.sh profile default    # 全部显示
cc-menu.sh profile minimal    # 精简模式
cc-menu.sh profile dev        # 开发者模式

# 查看当前配置
cc-menu.sh config
```

## 预设说明

| 预设 | 效果 |
|------|------|
| `default` | 所有技能可见 |
| `minimal` | 隐藏 document-skills, example-skills; 金融/投行仅菜单可见 |
| `dev` | 仅保留开发相关技能，其余全隐藏 |
| `custom` | 手动编辑 settings.json |

## 可用插件前缀

| 前缀 | 包含技能 |
|------|----------|
| `document-skills:` | docx, pdf, pptx, xlsx, frontend-design, brand-guidelines, ... |
| `example-skills:` | web-artifacts-builder, webapp-testing, canvas-design, ... |
| `claude-api:` | claude-api, ... |
| `financial-analysis:` | 3-statement-model, dcf, lbo, comps, ... |
| `pitch-agent:` | pitch-deck, sector-overview, ... |