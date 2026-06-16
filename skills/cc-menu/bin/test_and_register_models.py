import urllib.request
import json
import concurrent.futures
import re
import os
from pathlib import Path

# Load .env from parent directory (cc-menu root) if it exists
env_path = Path(__file__).resolve().parent.parent / ".env"
if env_path.exists():
    with env_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ[k.strip()] = v.strip().strip('"').strip("'")

PORT = int(os.environ.get("CPA_PORT", 8317))
TARGET_URL = os.environ.get("CPA_TARGET_URL", "https://your-remote-cpa-endpoint.com")
API_KEY = os.environ.get("CPA_API_KEY", "your-cpa-api-key-here")

REMOTE_MODELS_URL = f"{TARGET_URL}/v1/models"
LOCAL_MESSAGES_URL = f"http://127.0.0.1:{PORT}/v1/messages"

# 1. 获取所有可选模型
def get_remote_models():
    proxy_handler = urllib.request.ProxyHandler({})
    opener = urllib.request.build_opener(proxy_handler)
    urllib.request.install_opener(opener)
    
    req = urllib.request.Request(
        REMOTE_MODELS_URL,
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return sorted(list(set(m["id"] for m in data.get("data", []))))
    except Exception as e:
        print(f"Error fetching models list: {e}")
        return []

# 2. 测试单个模型是否可用
def test_model(model_name):
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 10
    }
    
    req = urllib.request.Request(
        LOCAL_MESSAGES_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-api-key": API_KEY,
            "anthropic-version": "2023-06-01"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp_data = json.loads(resp.read().decode("utf-8"))
            if "content" in resp_data:
                content = resp_data["content"]
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = "".join([part.get("text", "") for part in content if isinstance(part, dict)])
                
                print(f"[OK] Model: {model_name} -> Response: {repr(text.strip())}")
                return True, model_name, text.strip()
    except Exception as e:
        pass
    print(f"[FAIL] Model: {model_name}")
    return False, model_name, ""

def main():
    print("Fetching models from remote server...")
    candidates = get_remote_models()
    print(f"Found {len(candidates)} total candidates. Filtering and preparing tests...")
    
    keywords = ["qwen", "gpt", "grok", "claude", "deepseek", "kimi", "moonshot", "glm"]
    to_test = []
    for c in candidates:
        lower = c.lower()
        if any(kw in lower for kw in keywords) and "image" not in lower and "vl" not in lower:
            to_test.append(c)
    
    for important in ["qwen3.6-35b-a3b-nvfp4", "qwen3.6-plus", "gpt-5.5", "gpt-5.4", "grok-4.1-fast", "deepseek-ai/deepseek-v4-flash"]:
        if important not in to_test and important in candidates:
            to_test.append(important)
            
    to_test = sorted(list(set(to_test)))
    print(f"Starting concurrent testing of {len(to_test)} models...")
    
    verified_models = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        results = executor.map(test_model, to_test)
        for is_ok, model_name, response in results:
            if is_ok:
                verified_models.append(model_name)
                
    print(f"\nTest finished. Verified {len(verified_models)} active models:")
    for vm in verified_models:
        print(f" - {vm}")
        
    if not verified_models:
        print("No verified models active right now. Aborting auto-update to protect lists.")
        return
        
    qwen_series = []
    gpt_series = []
    claude_series = []
    grok_series = []
    deepseek_series = []
    others = []
    
    for m in verified_models:
        lower = m.lower()
        if "qwen" in lower:
            qwen_series.append(m)
        elif "gpt" in lower:
            gpt_series.append(m)
        elif "claude" in lower:
            claude_series.append(m)
        elif "grok" in lower:
            grok_series.append(m)
        elif "deepseek" in lower:
            deepseek_series.append(m)
        else:
            others.append(m)
            
    model_list_str = ""
    idx = 1
    
    if qwen_series:
        model_list_str += "\n### 🏮 Qwen (通义千问系列)\n"
        for m in qwen_series:
            desc = "当前默认模型，推理与编码核心担当。" if "nvfp4" in m.lower() else "阿里通义千问系列模型。"
            model_list_str += f"[{idx}] {m} -> {desc}\n"
            idx += 1
            
    if gpt_series:
        model_list_str += "\n### 🤖 GPT / OpenAI 系列\n"
        for m in gpt_series:
            desc = "旗舰级推理模型，适合超高难度算法。" if "5.5" in m else "高性能日常通用模型。"
            model_list_str += f"[{idx}] {m} -> {desc}\n"
            idx += 1
            
    if claude_series:
        model_list_str += "\n### 🦅 Claude / Anthropic 系列\n"
        for m in claude_series:
            model_list_str += f"[{idx}] {m} -> 官方原厂 Claude 模型接口。\n"
            idx += 1
            
    if grok_series:
        model_list_str += "\n### 🌌 Grok / xAI 系列\n"
        for m in grok_series:
            model_list_str += f"[{idx}] {m} -> 极速或思维模型，擅长架构与超长上下文。\n"
            idx += 1
            
    if deepseek_series:
        model_list_str += "\n### 🐬 DeepSeek 系列\n"
        for m in deepseek_series:
            model_list_str += f"[{idx}] {m} -> 高性能低时延，极速响应服务。\n"
            idx += 1
            
    if others:
        model_list_str += "\n### 🌟 其他可用系列\n"
        for m in others:
            model_list_str += f"[{idx}] {m} -> 多功能备用模型。\n"
            idx += 1

    # 5. 更新本地 models.md 命令
    claudedir = Path.home() / ".claude"
    models_file_path = claudedir / "commands" / "models.md"
    if models_file_path.exists():
        content = models_file_path.read_text(encoding="utf-8")
        pattern = r"(### 📋 CPA 平台可用模型列表\n)(.*?)(\n### 🚀 快捷切换指令)"
        new_content = re.sub(pattern, rf"\1{model_list_str}\3", content, flags=re.DOTALL)
        models_file_path.write_text(new_content, encoding="utf-8")
        print(f"Successfully updated {models_file_path} with verified models!")
        
    # 6. 更新 Obsidian 手册 (若存在)
    obsidian_file_path = Path("D:/obsidian-vault/03_Resources/04_技术文档/Claude Code - CPA 多模型驱动与本地消息清洗中间件配置手册.md")
    if obsidian_file_path.exists():
        content = obsidian_file_path.read_text(encoding="utf-8")
        pattern = r"(### 📋 CPA 平台可用模型列表\n)(.*?)(\n### 🚀 快捷切换指令)"
        new_content = re.sub(pattern, rf"\1{model_list_str}\3", content, flags=re.DOTALL)
        obsidian_file_path.write_text(new_content, encoding="utf-8")
        print(f"Successfully updated Obsidian manual at {obsidian_file_path}!")

if __name__ == "__main__":
    main()
