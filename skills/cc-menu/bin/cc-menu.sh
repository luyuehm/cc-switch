#!/usr/bin/env python3
"""cc-menu.sh — Claude Code 菜单管理 CLI 脚本
共享脚本，被 Claude Code skill 和 OpenClaw agent 共同调用
Usage: cc-menu.sh <action> [args...]
"""

import json
import os
import subprocess
import sys
from pathlib import Path

CLAUDEDIR = Path.home() / ".claude"
SETTINGS = CLAUDEDIR / "settings.json"
COMMANDSDIR = CLAUDEDIR / "commands"


def json_merge(key, value):
    cfg = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    cfg[key] = value
    SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))


def cmd_audit():
    print("📋 Claude Code 菜单审计报告\n")

    print("━━ 自定义斜杠命令 (commands/) ━━━━")
    if COMMANDSDIR.exists():
        for f in sorted(COMMANDSDIR.glob("*.md")):
            name = f.stem
            desc = ""
            for line in f.read_text().splitlines()[:10]:
                if line.startswith("description:"):
                    desc = line.split(":", 1)[1].strip().strip('"')
                    break
            print(f"  ✅ /{name} — {desc or '无描述'}")
    print()

    print("━━ 隐藏的技能 (skillOverrides) ━━━━")
    if SETTINGS.exists():
        cfg = json.loads(SETTINGS.read_text())
        ov = cfg.get("skillOverrides", {})
        if not ov:
            print("  (无)")
        else:
            for k, v in ov.items():
                print(f"  🔇 {k} → {v}")
    else:
        print("  (无)")
    print()

    print("━━ 插件技能 (plugins) ━━━━")
    if SETTINGS.exists():
        cfg = json.loads(SETTINGS.read_text())
        plugins = cfg.get("enabledPlugins", {})
        ov = cfg.get("skillOverrides", {})
        for p, enabled in plugins.items():
            if not enabled:
                continue
            hidden = [k for k in ov if k.startswith(f"{p}:") and ov[k] == "off"]
            status = f"{len(hidden)} 隐藏" if hidden else "全部可见"
            print(f"  📦 {p}: {status}")
    print()

    count = len(list(COMMANDSDIR.glob("*.md"))) if COMMANDSDIR.exists() else 0
    print(f"总计: {count} 自定义命令")


def cmd_hide(name):
    if not name:
        sys.exit("Usage: cc-menu.sh hide <skill-name|plugin:*>")

    cfg = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    ov = cfg.setdefault("skillOverrides", {})

    if ":" in name and name.endswith("*"):
        plugin = name.split(":")[0]
        ov[f"{plugin}:*"] = "off"
        print(f"🔇 隐藏插件 {plugin} 的全部技能")
    else:
        ov[name] = "off"
        print(f"🔇 隐藏技能: {name}")

    SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))


def cmd_show(name):
    if not name:
        sys.exit("Usage: cc-menu.sh show <skill-name|plugin:*>")

    if not SETTINGS.exists():
        print("⚠️ settings.json 不存在")
        return

    cfg = json.loads(SETTINGS.read_text())
    ov = cfg.get("skillOverrides", {})

    if ":" in name and name.endswith("*"):
        plugin = name.split(":")[0]
        keys = [k for k in ov if k.startswith(f"{plugin}:")]
        for k in keys:
            del ov[k]
        cfg["skillOverrides"] = ov
        SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
        print(f"✅ 恢复插件 {plugin} 的全部技能 ({len(keys)} 项)")
    else:
        if name in ov:
            del ov[name]
            cfg["skillOverrides"] = ov
            SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
            print(f"✅ 恢复显示: {name}")
        else:
            print(f"⚠️ {name} 未被隐藏，无需恢复")


def cmd_command(action, name, *args):
    if action == "create":
        desc = args[0] if args else "New command"
        hint = args[1] if len(args) > 1 else ""
        COMMANDSDIR.mkdir(parents=True, exist_ok=True)
        filepath = COMMANDSDIR / f"{name}.md"
        if filepath.exists():
            sys.exit(f"命令 /{name} 已存在")
        content = "---\ndescription: " + desc + "\n"
        if hint:
            content += f"argument-hint: {hint}\n"
        content += "---\n\n"
        filepath.write_text(content)
        print(f"✅ 创建自定义命令 /{name} → {filepath}")

    elif action == "remove":
        filepath = COMMANDSDIR / f"{name}.md"
        if not filepath.exists():
            sys.exit(f"命令 /{name} 不存在")
        filepath.unlink()
        print(f"✅ 删除自定义命令 /{name}")

    elif action == "list":
        print("📋 自定义斜杠命令列表:")
        if COMMANDSDIR.exists():
            for f in sorted(COMMANDSDIR.glob("*.md")):
                desc = ""
                for line in f.read_text().splitlines()[:10]:
                    if line.startswith("description:"):
                        desc = line.split(":", 1)[1].strip().strip('"')
                        break
                print(f"  /{f.stem} — {desc or '无描述'}")
    else:
        sys.exit(f"Unknown command action: {action} (use: create|remove|list)")


def cmd_config():
    if not SETTINGS.exists():
        print("⚠️ settings.json 不存在")
        return
    cfg = json.loads(SETTINGS.read_text())
    ov = cfg.get("skillOverrides", {})
    if ov:
        print("📋 当前 skillOverrides 配置:")
        print(json.dumps(ov, indent=2, ensure_ascii=False))
    else:
        print("📋 当前未配置 skillOverrides")


def cmd_profile(profile="default"):
    if profile == "default":
        cfg = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
        cfg.pop("skillOverrides", None)
        SETTINGS.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
        print("✅ 切换到 default 预设: 所有技能可见")

    elif profile == "minimal":
        json_merge("skillOverrides", {
            "document-skills:*": "off",
            "example-skills:*": "off",
            "financial-analysis:*": "user-invocable-only",
            "pitch-agent:*": "user-invocable-only",
            "claude-api:*": "name-only",
        })
        print("✅ 切换到 minimal 预设: 隐藏文档/示例技能，金融/投行技能仅菜单可见")

    elif profile == "dev":
        json_merge("skillOverrides", {
            "document-skills:*": "off",
            "example-skills:*": "off",
            "financial-analysis:*": "off",
            "pitch-agent:*": "off",
            "claude-api:claude-api": "user-invocable-only",
        })
        print("✅ 切换到 dev 预设: 仅保留开发相关技能")

    elif profile == "custom":
        print("📝 自定义模式: 请手动编辑 ~/.claude/settings.json 中的 skillOverrides")

    else:
        sys.exit(f"未知预设: {profile} (可用: default|minimal|dev|custom)")


def cmd_cleaner(action):
    script_dir = Path(__file__).parent
    cleaner_script = script_dir / "proxy_cpa_cleaner.py"
    tester_script = script_dir / "test_and_register_models.py"

    if action == "start":
        # Check if port is in use
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", 8317))
            s.close()
        except socket.error:
            print("[WARN] CPA Cleaner is already running or port 8317 is occupied.")
            return

        print("[STARTING] Starting Multi-threaded CPA Cleaner proxy...")
        import subprocess
        if sys.platform == "win32":
            # On Windows, launch as a detached process
            DETACHED_PROCESS = 0x00000008
            subprocess.Popen([sys.executable, str(cleaner_script)], creationflags=DETACHED_PROCESS, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            # On macOS / Linux, launch in background
            subprocess.Popen([sys.executable, str(cleaner_script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        print("[OK] CPA Cleaner started successfully on http://127.0.0.1:8317")
        print("[NOTE] CPA Cleaner is a local proxy — set ANTHROPIC_BASE_URL=http://127.0.0.1:8317 in settings.json to use it.")

    elif action == "stop":
        print("[STOPPING] Stopping CPA Cleaner proxy...")
        import subprocess
        if sys.platform == "win32":
            # Windows: kill using PowerShell command
            cmd = "powershell -Command \"Stop-Process -Id (Get-NetTCPConnection -LocalPort 8317 -ErrorAction SilentlyContinue).OwningProcess -Force\""
            subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            # macOS / Linux: kill using lsof and kill
            subprocess.run("kill -9 $(lsof -t -i:8317)", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("[OK] CPA Cleaner stopped.")

    elif action == "status":
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", 8317))
            s.close()
            print("[STOPPED] CPA Cleaner Status: Stopped (Port 8317 is free)")
        except socket.error:
            print("[RUNNING] CPA Cleaner Status: Running (Port 8317 is occupied)")

    elif action == "test":
        print("[SCAN] Scanning and testing remote CPA models...")
        import subprocess
        subprocess.run([sys.executable, str(tester_script)])

    else:
        sys.exit("Unknown cleaner action: use start|stop|status|test")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "audit"
    args = sys.argv[2:]

    actions = {
        "audit": lambda: cmd_audit(),
        "status": lambda: cmd_audit(),
        "list": lambda: cmd_audit(),
        "hide": lambda: cmd_hide(args[0] if args else ""),
        "show": lambda: cmd_show(args[0] if args else ""),
        "unhide": lambda: cmd_show(args[0] if args else ""),
        "command": lambda: cmd_command(*args),
        "cmd": lambda: cmd_command(*args),
        "config": lambda: cmd_config(),
        "show-config": lambda: cmd_config(),
        "profile": lambda: cmd_profile(args[0] if args else "default"),
        "preset": lambda: cmd_profile(args[0] if args else "default"),
        "cleaner": lambda: cmd_cleaner(args[0] if args else "status"),
    }

    fn = actions.get(action)
    if fn:
        fn()
    else:
        print("Usage: cc-menu.sh <action> [args]")
        print()
        print("Actions:")
        print("  audit                         审计当前菜单")
        print("  hide <name|plugin:*>          隐藏技能")
        print("  show <name|plugin:*>          恢复显示")
        print("  command create <name> <desc>  创建自定义命令")
        print("  command remove <name>         删除自定义命令")
        print("  command list                  列出自定义命令")
        print("  config                        查看 skillOverrides")
        print("  profile <name>                切换预设 (default|minimal|dev|custom)")
        print("  cleaner start                 启动 CPA Cleaner（可选组件，需另行配置 ANTHROPIC_BASE_URL）")
        print("  cleaner stop                  停止 CPA Cleaner")
        print("  cleaner status                查看中间件运行状态")
        print("  cleaner test                  自动测试远程 CPA 模型并动态注册到列表")



if __name__ == "__main__":
    main()