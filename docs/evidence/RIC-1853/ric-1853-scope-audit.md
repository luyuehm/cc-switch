# RIC-1853 证据 — cc-switch 提交范围审计（BLOCKED，未提交/未推送）

生成时间: 2026-10-22T20:42:39Z
目标仓库: https://github.com/luyuehm/cc-switch.git
分支: master
本地 HEAD: 80380560cdc386db2f2d5558ad2c5f2dac275f22
远端 master: 80380560cdc386db2f2d5558ad2c5f2dac275f22
HEAD == origin/master: YES

## github 权限证据
gh repo view luyuehm/cc-switch -> isFork:false, parent:null, viewerPermission:ADMIN, defaultBranchRef:master
结论: 可写自有远端，非真上游。权限不构成 blocker。

## 关键发现：RIC-1851 不在仓库工作副本中

文件                                                     1845     1851     行数  
cc-switch.sh(仓库工作副本)                           5        0        2116    
~/.claude/cc-switch.sh(运行态)                          5        4        2176    
HEAD:cc-switch.sh(d6d3a98)                                 0        0        1821    
备份 .bak-RIC1851-20261023-040505                        5        0        2116    

证明: 仓库工作副本与 .bak-RIC1851 备份字节一致 = 两者都是 RIC-1851 应用之前的快照。
  -> IDENTICAL

## diff 构成
  HEAD(d6d3a98) -> 仓库工作副本: 383 insertions, 88 deletions(单文件 cc-switch.sh)
  仓库工作副本 -> 运行态文件: 106 changed lines / 19 hunks，全部属于 RIC-1851

## 验收测试矩阵（仓库工作副本）

| 项 | 结果 |
|---|---|
| zsh -n / bash -n | PASS |
| a- 与 bare 在保存时保持独立 | PASS |
| --remove --id 原始 ID 精确比较（删 deepseek-flash 不动 a-deepseek-flash） | PASS |
| CC_SETTINGS_PATH 写入（export 时） | PASS |
| CC_SETTINGS_PATH 写入（未 export，即 .zshrc source 的真实场景） | FAIL (RC=1) |
| 保存失败不打印 OK 假成功 | FAIL (仍打印 [OK], EXIT=0) |

## 失败复现（原样粘贴）

命令: env -u CC_SETTINGS_PATH HOME=<tmp> ... zsh -c "source ./cc-switch.sh; cc-sync --remove --id=stale-model"
输出:
```
Traceback (most recent call last):
  File "<string>", line 52, in <module>
    with open(os.environ['CC_SETTINGS_PATH'], 'w') as f:
KeyError: 'CC_SETTINGS_PATH'
[OK]  Removed 'stale-model' from availableModels.
EXIT=0
```
settings.json 未被修改（stale-model 仍在）—— 即 RIC-1851 所描述的假成功。

## 对照组：运行态文件（含 RIC-1851）已验证通过
  - 默认 HOME 路径保存: RC=0，两个 ID 均保留
  - 目标不可写: RC=3, stderr 'failed to save settings ... (exit 3)'，无假 OK

## 结论
issue 声明的两项修复只有 RIC-1845 在仓库工作副本中；RIC-1851 仅存在于 ~/.claude 运行态文件，
而 issue 明确禁止提交 ~/.claude 运行态文件。按 issue 第 3 条，标 blocked，未 commit、未 push。

## 修复建议（供人决定）
把 ~/.claude/cc-switch.sh 相对仓库工作副本的 19 个 hunk（纯 RIC-1851：__cc_read_settings 不覆盖坏 JSON、
__cc_save_settings 显式传递 CC_SETTINGS_PATH + 原子写 + 失败码、11 处调用点加 || return 1、
skill-restore 的 sed '$d' 与换行修正）合入 cc-switch.sh 后重跑同一矩阵，即可两修复齐全。

---

## 后续处置（2026-11-16 复核）

本审计记录的 BLOCKED 状态已解除，结论随之失效——保留原文以存证，以下为当前事实：

| 项 | 审计时 (HEAD 8038056) | 当前 (v2.6.0) |
|---|---|---|
| RIC-1851 在仓库工作副本 | 0 处 | **4 处** |
| RIC-1851 在运行态副本 | 4 处 | 4 处 |
| RIC-1851 在 `origin/master` | 未查 | **4 处** |
| 处置 | 标 blocked，未提交 | 修复已于 v2.6.0 合入并发布 |

解除 blocker 的提交是 `fb4e1c5`（"fix(cc-switch.sh): keep a- model IDs distinct and make settings
saves durable"），即本审计「修复建议」中描述的 19 个 hunk 已进入主干，而非仅存在于 `~/.claude`
运行态文件。

复跑 `tests/ric-1851-regression.sh` 对 v2.6.0 的 11 项检查全部通过（PASS=11 FAIL=0），其中
`CC_SETTINGS_PATH write without export` 一项正是本审计复现的 `KeyError` 场景。

**结论：本 issue 已关闭，无需再提交。** 本文档仅作历史留证。
