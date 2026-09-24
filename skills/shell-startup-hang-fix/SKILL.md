---
name: shell-startup-hang-fix
description: '诊断并修复 shell 启动卡死/极慢（开终端或 source ~/.zshrc 卡住数秒到 60 秒）。覆盖 pyenv 锁残留、安全门禁 rm 的 PATH-shim 劫持脚本、fpath 膨胀致 .zcompdump 每次重建三类根因，含分段计时 / xtrace / 干净环境对比 / 二分定位的通用方法论与验证闭环。Trigger: /shellfix, 开shell卡住, 终端启动慢, source zshrc 卡住, shell启动60秒'
trigger: /shellfix
---

# Shell Startup Hang Fix

使用场景：**打开终端或 `source ~/.zshrc` 时卡住**（数秒到 60 秒），或每次启动都刷一堆重复输出。

适用平台：**macOS + zsh**（Homebrew / oh-my-zsh / pyenv 组合）。排查方法论（第 5 节）可迁移到任何"启动慢"场景。

核心原则：**先量，再猜。** 恒定时长（如每次都是 60s）几乎总是**超时重试**；渐进变慢 / 每次刷重复日志多半是**累积膨胀**。两类根因的处理方式完全不同。

---

## 0. 三类根因速判表

| 类型 | 典型症状 | 一句话根因 | 关键验证 |
|---|---|---|---|
| **A. 超时重试** | 启动**恒定 ~60s**，输出含 `for 60 seconds` | 某工具抢锁失败后重试到超时上限 | `ls ~/.pyenv/shims/.pyenv-shim` |
| **B. 删除被劫持** | 启动刷一堆 `🛡️ 安全门禁`；工具清理/重建异常 | PATH 上的 `rm` shim 劫持了**所有脚本**的删除 | `whence -p rm` 非 `/bin/rm` |
| **C. 累积膨胀** | 启动慢 1~3s，每次全量重建补全缓存 | 环境变量（fpath/FPATH）继承叠加 → 缓存元数据永不一致 | `${#fpath}` vs `${#${(u)fpath[@]}}` |

> A 与 B 常**互为因果**：B 让工具无法正常释放锁 → 产生 A。修完 A 务必检查 B，否则必复发。

---

## 1. 现场诊断（按序执行，只读）

```bash
# 1. 量总时长（正常应 <3s；>5s 即异常）
time zsh -i -c 'true'

# 2. 汇总所有 stderr 输出 —— 告警/超时/被拦截的记录都在这里
zsh -i -c 'true' 2>&1 | grep -vE '^\s*$' | sort | uniq -c | sort -nr | head -20

# 3. 若每次都是恒定时长 → 直接查锁/超时类残留
ls -la ~/.pyenv/shims/.pyenv-shim 2>/dev/null && echo "★ pyenv 锁残留"

# 4. 查 rm 是否被 PATH shim 劫持（关键：脚本看 PATH，不看 alias）
whence -p rm     # 期望 /bin/rm；若是 ~/.local/bin/rm 之类 → 所有脚本的删除已被劫持
type rm          # 看 alias（alias 只影响交互输入，不影响脚本）

# 5. 查补全路径是否膨胀（注意 [@] 不能省，见下方陷阱）
zsh -i -c 'echo "total=${#fpath} uniq=${#${(u)fpath[@]}}"' 2>/dev/null
# 两者不相等 → 有重复项，即类型 C。
# ⚠️ 陷阱：写成 ${#${(u)fpath}}（漏掉 [@]）会把数组当字符串，${#...} 数的是"字符数"，
#    如 11 条路径会得到 467 —— 看起来"严重膨胀"，其实是误报。务必带 [@]。
```

**排除项**（这次实测已否证，别重复走）：`trash` 本身不慢（实测 0s 返回）；与系统负载、磁盘速度无关；`~/.zcompdump` 体积无关。

---

## 2. 根因 A：pyenv 锁残留 → 恒定 60 秒

### 症状
启动固定卡 60 秒，输出：

```
pyenv: cannot rehash: couldn't acquire lock /Users/<u>/.pyenv/shims/.pyenv-shim for 60 seconds.
Last error message:
/opt/homebrew/Cellar/pyenv/<ver>/libexec/pyenv-rehash: line 22: .../.pyenv-shim: cannot overwrite existing file
```

### 机制
1. `.zshrc` 的 `eval "$(pyenv init -)"` 会让**每次 shell 启动**执行 `command pyenv rehash`（`pyenv-init` 的 `print_rehash`）。
2. `pyenv-rehash` 的 `acquire_lock()` 用 `set -o noclobber; echo -n > "$PROTOTYPE_SHIM_PATH"` 抢锁；抢不到就每 `0.1s` 重试，直到 `PYENV_REHASH_TIMEOUT`（默认 **60**）秒才放弃 → 每次启动死等 60 秒。
3. 锁的释放靠 `rm -f`（`remove_prototype_shim()` / `trap release_lock EXIT`）。若 `rm` 被劫持成"搬进废纸篓"这种可中断的重操作，**中断一次锁就永久残留** → 必然复发。

### 复现（不占满 60 秒）
```bash
PYENV_REHASH_TIMEOUT=3 pyenv rehash    # 3 秒内必失败，即确认
```

### 修复
```bash
trash ~/.pyenv/shims/.pyenv-shim      # 清掉残留锁
pyenv rehash                           # 应在 1s 内 rc=0，且结束后不再留锁
ls ~/.pyenv/shims/.pyenv-shim 2>/dev/null || echo "已释放 ✅"
ls ~/.pyenv/shims/ | wc -l             # shim 应完好（本机 68 个）
```

> ⚠️ **不要**用 `rm -f ~/.pyenv/shims/*` 之类的"重建"思路。`pyenv-rehash` 的 `remove_outdated_shims()` 里有 `rm -f "$SHIM_PATH"/*`，一旦触发而 `rm` 又被劫持，68 个 shim 会**全部被搬进废纸篓**。

### 防复发
清锁只是止血。若根因 B 未修，锁会再次残留 → **必须继续做第 3 节**。

---

## 3. 根因 B：`rm` 的 PATH shim 劫持所有脚本

### 症状
- 启动时刷 `🛡️ [安全门禁生效] 拦截未审批的底层删除！`
- 临时文件/锁文件被搬进废纸篓而非删除
- 依赖 `rm -f` 语义的工具行为异常（pyenv / git / npm / 构建脚本）
- 反复产生根因 A

### 关键区分（这是最容易搞错的地方）

| 形态 | 影响范围 | `command rm` 能否绕过 |
|---|---|---|
| **alias `rm=...`** | 只管**交互输入**，脚本完全不受影响 | ✅ 能绕过 |
| **PATH 上的 `~/.local/bin/rm`** | **劫持所有脚本**（alias 对脚本无效，PATH 有效） | ❌ **绕不过** |

```bash
# 判定
whence -p rm        # 落在 /bin/rm → 只有 alias，脚本安全
                    # 落在 ~/.local/bin/rm 等 → 脚本已被劫持
type rm             # rm is an alias for ... → 仅交互层
```

### 修复：收窄作用域，门禁只拦人、不拦工具
```bash
# 备份后移走 PATH 版本，只保留 alias
cp -p ~/.local/bin/rm ~/.local/bin/rm.gate-backup-$(date +%Y%m%d)
trash ~/.local/bin/rm

# 验证
whence -p rm                 # 应回到 /bin/rm（脚本安全）
zsh -i -c 'type rm' 2>/dev/null   # 仍应显示 alias（交互仍受保护）
```

### 原则
**安全门禁只该拦人，不该拦工具。** 给 `rm` 挂 PATH shim 会静默破坏一切依赖 `rm -f` 语义的程序。若将来要恢复 PATH 版，必须给 pyenv 一类工具留白名单，否则 60 秒卡顿必然复发。

---

## 4. 根因 C：fpath 膨胀 → `.zcompdump` 每次重建

### 症状
- 启动慢 1~3s（不如 A 那么夸张，但每次都在浪费）
- 每次启动都全量 `compinit`；`.zcompdump`（及其 `.zwc.old`/`.lock`）被反复重建 / 被搬进废纸篓

### 机制
1. oh-my-zsh 的 `oh-my-zsh.sh` 把 `fpath` 快照写进 dump 元数据行 `#omz fpath:`，下次启动比对；不一致就 `command rm -f "$ZSH_COMPDUMP"` 并全量重建。
2. **`brew shellenv` 会执行 `fpath[1,0]="$HOMEBREW_PREFIX/share/zsh/site-functions"; export FPATH`** —— 它不只是设 PATH，还改 fpath 且导出。
3. 若 `.zshrc` 里 `brew shellenv` 被调用**多次**，每层子 shell 都继承父 shell 已膨胀的 fpath 再叠一次；而 oh-my-zsh 的 `fpath=(...)` 前置**不做去重**（实测 13 条 → 31 条，同一目录重复 2~4 份）。
4. 于是**终端链 / Claude 链 / 子进程各算出不同 fpath，却共用同一个 `~/.zcompdump`** → 谁启动都对不上 → 每次都重建。

### 诊断
```bash
# 1. 重复项数量（[@] 必带，否则数的是字符数而误报）
zsh -i -c 'echo "total=${#fpath} uniq=${#${(u)fpath[@]}}"' 2>/dev/null

# 2. xtrace 抓出"算出的元数据"，看谁在改 fpath
zsh -i -x -c 'true' 2>/tmp/xt.log >/dev/null
grep -a "zcompdump_fpath=" /tmp/xt.log | head -1
grep -aE "fpath\[1,0\]|export FPATH" /tmp/xt.log | head   # 揪出 brew shellenv 之类
# 解读：保留一次 brew shellenv 是正常的 —— 它本就会 fpath[1,0]=... 并 export FPATH
#   （本机位于 .zshrc 首个 brew shellenv，xtrace 里显示为 `.zshrc:13> eval $'...fpath[1,0]=...;export FPATH;'`）。
#   要抓的是**第二次及以后**的重复调用（不同行号出现相同的 fpath[1,0]/export FPATH）。
#   判据：若某次 eval 之后**没有**你的 fpath 重置块再兜底，fpath 就会向子 shell 泄漏 → 即类型 C 根因。

# 3. 算出的值 vs dump 里记录的值 做逐行 diff（比"看着差不多"可靠）
# 钉住"当前活动的" compdump：它由 oh-my-zsh 按 SHORT_HOST 生成，直接用 $ZSH_COMPDUMP 最稳
CD=$(zsh -i -c 'echo $ZSH_COMPDUMP' 2>/dev/null | tail -1)
echo "活动 compdump: $CD"
grep -a "#omz fpath:" "$CD" | tail -1 | sed 's/^#omz fpath: //' | tr ' ' '\n' | grep -v '^$' > /tmp/rec.txt
# ⚠️ 勿用 ~/.zcompdump-* 通配：本机有 24 个历史 dump（含其他主机名）与 .lock 目录，
#    tail -1 会取到旧文件甚或目录，导致对比"恒等"而产生假阳性。
# 与 /tmp/xt.log 里计算出的值同样处理后 diff
diff /tmp/calc.txt /tmp/rec.txt
```

### 修复
在 `source $ZSH/oh-my-zsh.sh` **之前**把 fpath 重置为常量（不从父 shell 继承）+ 去重 + 切断导出：

```zsh
fpath=(
  /opt/homebrew/share/zsh/site-functions
  /usr/local/share/zsh/site-functions
  /usr/share/zsh/site-functions
  /usr/share/zsh/$ZSH_VERSION/functions
)
typeset -gU fpath
typeset +x FPATH
```

同时**删掉多余的 `eval "$(brew shellenv)"`**（只保留第一次）。否则它会在 `typeset +x FPATH` 之后重新 `export FPATH`，使该行失效。

> 上述 4 条是 `zsh -f -c 'print -l -- $fpath'` 的 zsh 内置默认(3) + brew 补全源(1)，oh-my-zsh 会在其后自动前置自己的目录，**不丢任何补全来源**。

**改动前先备份 `~/.zshrc`**，且这是持久化 shell profile —— 需用户明确同意后再改。

### 附：`/usr/local/share/zsh/site-functions` 被剔除
`compaudit` 会把**组可写且主组不是 root** 的目录判为不安全，被 `compinit -i` 从 fpath 剔除。本机该目录是 `<user>:admin drwxrwxr-x` 而主组是 `staff` → 被剔除（**非本类问题的回归**）。想启用它的补全：
```bash
sudo chmod g-w /usr/local/share/zsh{,/site-functions}
# 或 sudo chown -R root:wheel /usr/local/share/zsh
```

---

## 5. 通用排查方法论（可迁移到任何"启动慢"）

```text
1. 先量总时长          time zsh -i -c 'true'
   └ 恒定值 → 怀疑超时重试；渐进值 → 怀疑累积膨胀

2. 加时间戳标记阶段    zsh -i -c 'date +%s.%N; <动作>; date +%s.%N'
   └ 本机曾用它证明"整段 60s 都在 rc 加载期"

3. 汇总 stderr        逐条 uniq -c，被劫持/超时的告警都在输出里

4. xtrace 抓赋值      zsh -i -x -c 'true' 2>/tmp/xt.log
   └ 定位"谁把变量改成了什么"，比读配置猜快得多

5. 干净环境对比        env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
                        TERM=xterm SHELL=/bin/zsh /bin/zsh -l -i -c '...'
   └ 区分「配置本身的问题」vs「从父 shell 继承来的污染」—— 这一步最关键

6. 二分定位           分段 source .zshrc（注意勿切断数组赋值语句）
   └ 适用于不清楚是哪一段引入的

7. 证据链闭合         算出的值 vs 记录的值 做 diff / md5，不靠"看着差不多"
```

**为什么第 5 步关键**：本机 `zsh -i`（继承父环境）与 `env -i ... zsh -l -i`（全干净）算出的 fpath 不同，而两者共用同一个 `.zcompdump` —— 只看单条链**永远发现不了**这个不一致。

---

## 6. 验证闭环（改完必跑）

```bash
# 1. 启动耗时 + 是否还有被拦截的删除（连测 4 次，应稳定且全 0）
for i in 1 2 3 4; do
  s=$(date +%s.%N)
  out=$(zsh -i -c 'true' 2>&1)
  e=$(date +%s.%N)
  echo "run$i: $(echo "$e-$s" | bc)s | 拦截数=$(printf '%s\n' "$out" | grep -c '安全门禁')"
done

# 2. compdump 是否还在被重建（应为 0）；钉住活动文件而非通配
CD=$(zsh -i -c 'echo $ZSH_COMPDUMP' 2>/dev/null | tail -1)
zsh -i -c 'true' 2>&1 | grep -c "zcompdump-.*-5.9$"

# 3. 跨链元数据一致性（两条链 md5 必须相同）
#    先钉住活动 compdump（勿用 ~/.zcompdump-* 通配，见第 4 节警告）
CD=$(zsh -i -c 'echo $ZSH_COMPDUMP' 2>/dev/null | tail -1)
a=$(zsh -i -c 'true' >/dev/null 2>&1; grep -a '#omz fpath:' "$CD" | tail -1 | md5)
b=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm SHELL=/bin/zsh \
      /bin/zsh -l -i -c 'true' >/dev/null 2>&1; grep -a '#omz fpath:' "$CD" | tail -1 | md5)
echo "链A=$a"; echo "链B=$b"
[ "$a" = "$b" ] && echo "✅ 跨链一致" || echo "❌ 仍不一致"

# 4. 关键工具解析未变（改 PATH/fpath 后必查）
zsh -i -c 'for c in brew node npm python3 git pyenv go kubectl; do \
  printf "%-8s %s\n" "$c" "$(command -v $c 2>/dev/null || echo 未找到)"; done'

# 5. pyenv 功能正常
zsh -i -c 'python3 --version; pyenv rehash && echo "rehash OK, 残留锁: $(ls ~/.pyenv/shims/.pyenv-shim 2>/dev/null || echo 无)"'
```

### 验收口径（本机 2026-09-24 修复后实测基线）
| 指标 | 修复前 | 修复后 |
|---|---|---|
| shell 启动 | 60s+（超时） | **1.8~2.8s** |
| compdump 重建 | 每次启动 | **0 次** |
| 被拦截的删除 | 每次 2~4 个 | **0** |
| fpath 条数 | 13 → 31 持续膨胀 | **11 恒定** |
| FPATH 导出 | `exported=1` | **`exported=0`** |
| 跨链元数据 md5 | 不一致 | **完全相同** |
| `pyenv rehash` | 60s 后失败 | **0s, rc=0** |
| 交互式 `rm` 门禁 | 有 | **仍保留** |

**最后一步：让用户开新终端**（或 `source ~/.zshrc`），清掉旧 shell 里已导出的那份环境变量。

---

## 7. 变更留痕清单

每次改动都应留下：
- 备份：`cp ~/.zshrc ~/.zshrc.bak-$(date +%Y%m%d-%H%M%S)`
- 移走的文件走废纸篓（可恢复），并另存一份：`~/.local/bin/rm.gate-backup-<date>`
- 记录到 memory：`shell-startup-60s-pyenv-stale-lock` / `shell-safety-gate-path-shim-scope` / `shell-fpath-compdump-rebuild-fix`
