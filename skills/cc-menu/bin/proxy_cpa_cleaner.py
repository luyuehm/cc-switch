import json
import http.server
import urllib.request
import sys
import os
import time
from pathlib import Path

# ────────────────────────────────────────────────────────────
#  Local CPA Cleaner & Multi-Provider Router
# ────────────────────────────────────────────────────────────

# Load .env from parent directory (cc-menu root) if it exists
env_path = Path(__file__).resolve().parent.parent / ".env"
if env_path.exists():
    with env_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ[k.strip()] = v.strip().strip('"').strip("'")

# 读取配置变量（支持本地 .env 文件）
PORT = int(os.environ.get("CPA_PORT", 8317))

# 默认 CPA 网关配置
DEFAULT_CPA_URL = os.environ.get("CPA_TARGET_URL", "https://your-remote-cpa-endpoint.com")
DEFAULT_CPA_KEY = os.environ.get("CPA_API_KEY", "your-cpa-api-key-here")

# 增加 SenseNova 第三方原生渠道支持
SENSENOVA_URL = os.environ.get("SENSENOVA_TARGET_URL", "https://token.sensenova.cn")
SENSENOVA_KEY = os.environ.get("SENSENOVA_API_KEY", "sk-vCM4QEx2WrfHRFhpHPWccA835WFm8TXT")

proxy_handler = urllib.request.ProxyHandler({})
opener = urllib.request.build_opener(proxy_handler)
urllib.request.install_opener(opener)

# ────────────────────────────────────────────────────────────
#  Task-based Smart Model Router (方案 B)
# ────────────────────────────────────────────────────────────

# Enable/disable smart routing via environment variable (default: on)
CPA_SMART_ROUTING = os.environ.get("CPA_SMART_ROUTING", "true").lower() == "true"

# Task → optimal model mapping. Each task can have a primary model and fallbacks.
# When a model returns quota/rate-limit errors, the next fallback is tried.
# All models are filtered against the CPA model list to ensure they actually exist.
TASK_MODEL_MAP = {
    "coding":  {"primary": "gpt-5.5",
                "fallbacks": ["deepseek-v4-flash", "qwen3.6-plus"]},
    "reason":  {"primary": "qwen3.6-plus",
                "fallbacks": ["gpt-5.5", "deepseek-v4-flash"]},
    "quick":   {"primary": "deepseek-v4-flash",
                "fallbacks": ["gpt-5.5", "qwen3.6-plus"]},
    "image":   {"primary": "gpt-5.5",
                "fallbacks": ["deepseek-v4-flash"]},
    "default": {"primary": None,
                "fallbacks": []},   # Keep whatever model Claude Code sent
}

# ────────────────────────────────────────────────────────────
#  CPA Model List Cache (from settings.json + /v1/models)
# ────────────────────────────────────────────────────────────

SETTINGS_PATH = Path.home() / ".claude" / "settings.json"

def _load_cpa_models():
    """Load the CPA model list from settings.json availableModels."""
    try:
        if SETTINGS_PATH.exists():
            cfg = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
            models = cfg.get("availableModels", [])
            if models:
                return set(models)
    except Exception as e:
        print(f"[WARN] Failed to load settings.json: {e}")
    return set()

# Refresh the model list periodically
_cpa_models = _load_cpa_models()
_CPA_MODELS_LAST_REFRESH = time.time()

def _refresh_cpa_models():
    """Refresh the CPA model cache. Called every 60 seconds."""
    global _cpa_models, _CPA_MODELS_LAST_REFRESH
    now = time.time()
    if now - _CPA_MODELS_LAST_REFRESH > 60:
        _cpa_models = _load_cpa_models()
        _CPA_MODELS_LAST_REFRESH = now

def is_model_in_cpa(model):
    """Check if a model exists in the CPA model list (case-insensitive)."""
    _refresh_cpa_models()
    if not _cpa_models:
        return True  # no list available, allow all
    return model.lower() in {m.lower() for m in _cpa_models}

# ────────────────────────────────────────────────────────────
#  Model Health Tracker (quota-aware)
# ────────────────────────────────────────────────────────────

# Tracks consecutive failures per model. After FAIL_THRESHOLD failures
# in a row, the model is marked unhealthy and skipped.
# Clears after HEALTH_RESET_SECONDS of no errors.

FAIL_THRESHOLD = 3                          # Consecutive failures before marking unhealthy
HEALTH_RESET_SECONDS = 120                  # Reset health after this many seconds
_model_health = {}                           # model_name -> {"failures": int, "last_fail": float, "healthy": bool}


def _ensure_health(model):
    """Initialize health tracking for a model if not yet tracked."""
    if model not in _model_health:
        _model_health[model] = {"failures": 0, "last_fail": 0.0, "healthy": True}


def is_model_healthy(model):
    """Check if a model is healthy. Auto-recovers after HEALTH_RESET_SECONDS."""
    _ensure_health(model)
    h = _model_health[model]
    if not h["healthy"]:
        elapsed = time.time() - h["last_fail"]
        if elapsed > HEALTH_RESET_SECONDS:
            h["failures"] = 0
            h["healthy"] = True
            print(f"[HEALTH] {model} recovered after {elapsed:.0f}s cooldown")
    return h["healthy"]


def mark_model_failure(model):
    """Record a model failure. Marks unhealthy after FAIL_THRESHOLD consecutive failures."""
    _ensure_health(model)
    h = _model_health[model]
    h["failures"] += 1
    h["last_fail"] = time.time()
    if h["failures"] >= FAIL_THRESHOLD:
        h["healthy"] = False
        print(f"[HEALTH] {model} UNHEALTHY after {h['failures']} consecutive failures (quota/rate-limit)")
    else:
        print(f"[HEALTH] {model} failure {h['failures']}/{FAIL_THRESHOLD}")


def mark_model_success(model):
    """Record a model success. Resets failure counter."""
    _ensure_health(model)
    h = _model_health[model]
    if h["failures"] > 0:
        h["failures"] = 0
        print(f"[HEALTH] {model} success, failure counter reset")


def is_quota_error(error_code, error_body=""):
    """Detect if an error is quota/rate-limit/insufficient related."""
    if error_code in (429, 403, 402):
        return True
    quota_kws = ["quota", "insufficient", "rate limit", "rate_limit",
                 "too many", "exhausted", "balance", "payment required",
                 "insufficient_quota", "超出配额", "额度不足", "余额不足",
                 "被限流", "rate limit exceeded", "limit reached"]
    err_lower = error_body.lower()
    return any(kw in err_lower for kw in quota_kws)


def get_routed_model(task_type):
    """Get the best healthy model for a task type.
    Tries primary first, then fallbacks in order.
    Filters against CPA model list (is_model_in_cpa).
    Returns model name string, or None if all models are unhealthy.
    """
    mapping = TASK_MODEL_MAP.get(task_type, TASK_MODEL_MAP["default"])

    candidates = []
    if mapping["primary"]:
        candidates.append(mapping["primary"])
    candidates.extend(mapping["fallbacks"])

    for model in candidates:
        if model and is_model_healthy(model) and is_model_in_cpa(model):
            return model

    # All candidates unhealthy or not in CPA list — force-reset the primary
    if mapping["primary"]:
        if not is_model_in_cpa(mapping["primary"]):
            print(f"[ROUTER] Primary {mapping['primary']} not in CPA model list, using original model")
            return None
        print(f"[HEALTH] All fallbacks unhealthy for task={task_type}, force-using primary {mapping['primary']}")
        _ensure_health(mapping["primary"])
        _model_health[mapping["primary"]]["healthy"] = True
        _model_health[mapping["primary"]]["failures"] = 0
        return mapping["primary"]
    return None


def classify_task(messages, system_text=""):
    """Analyze conversation content to determine task type for optimal model routing.

    Scans user messages and system prompt for keywords indicating what kind of
    work is being requested, then returns a task type key into TASK_MODEL_MAP.
    """
    combined = (system_text or "").lower()
    for msg in messages:
        if msg.get("role") != "user":
            continue
        content = msg.get("content", "")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    combined += " " + part.get("text", "").lower()
        elif isinstance(content, str):
            combined += " " + content.lower()

    # Image generation keywords
    if any(kw in combined for kw in
           ["画图", "生成图片", "create image", "generate image",
            "draw", "image of", "gpt-image", "illustrate", "visualize"]):
        return "image"

    # Strong reasoning / deep analysis (requires 2+ keyword matches)
    reasoning_kws = ["分析", "analyze", "比较", "compare", "对比",
                     "推理", "reason", "为什么", "why", "如何实现",
                     "how to", "解释", "explain", "总结", "summarize",
                     "deep think", "think step by step", "论证", "evaluate"]
    if sum(1 for kw in reasoning_kws if kw in combined) >= 2:
        return "reason"

    # Coding / development work
    if any(kw in combined for kw in
           ["代码", "code", "写一个", "实现", "implement",
            "function", "bug", "fix", "refactor", "debug",
            "compile", "test", "deploy", "git", "api",
            "endpoint", "database", "sql", "query", "pull request"]):
        return "coding"

    # Quick / simple tasks
    if any(kw in combined for kw in
           ["翻译", "translate", "convert", "hello", "hi", "简单"]):
        return "quick"

    return "default"


def classify_and_route(body, messages, system_text):
    """Apply smart routing: override model based on task classification + health.

    Returns the (possibly modified) model name and logs the routing decision.
    """
    if not CPA_SMART_ROUTING:
        return body.get("model", "")

    original_model = body.get("model", "")
    task_type = classify_task(messages, system_text)
    smart_model = get_routed_model(task_type)

    if smart_model:
        body["model"] = smart_model
        if smart_model != original_model:
            print(f"[SMART ROUTER] Task={task_type} | {original_model} → {smart_model}")
        else:
            print(f"[SMART ROUTER] Task={task_type} | keep {smart_model} (healthy)")
    else:
        body["model"] = original_model
        print(f"[SMART ROUTER] Task={task_type} | no route, keep {original_model}")

    return body["model"]


def translate_tools_to_openai(anth_tools):
    openai_tools = []
    for tool in anth_tools:
        openai_tools.append({
            "type": "function",
            "function": {
                "name": tool.get("name"),
                "description": tool.get("description"),
                "parameters": tool.get("input_schema", {})
            }
        })
    return openai_tools

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            # 读取本地 Claude Code 发送的原始请求
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            
            is_stream = body.get("stream", False)
            model_name = body.get("model", "")

            # ──────────────────────────────────────────────────
            #  1. 消息合并与清洗 (CPA Cleaner)
            # ──────────────────────────────────────────────────
            system_parts = []
            
            # 提取顶层 system 参数
            system_param = body.get("system")
            if system_param:
                if isinstance(system_param, str):
                    system_parts.append(system_param)
                elif isinstance(system_param, list):
                    for part in system_param:
                        if isinstance(part, dict) and part.get("type") == "text":
                            system_parts.append(part.get("text", ""))
                        elif isinstance(part, str):
                            system_parts.append(part)
            
            # 检索并剥离 messages 列表中残留的 system 消息
            other_messages = []
            for msg in body.get("messages", []):
                role = msg.get("role")
                content = msg.get("content")
                if role == "system":
                    if isinstance(content, str):
                        if content.strip():
                            system_parts.append(content)
                    elif isinstance(content, list):
                        for part in content:
                            if isinstance(part, dict) and part.get("type") == "text":
                                system_parts.append(part.get("text", ""))
                            elif isinstance(part, str):
                                system_parts.append(part)
                else:
                    other_messages.append({"role": role, "content": content})
            
            # 重组为标准干净格式
            cleaned_req = {
                "model": model_name,
                "messages": other_messages
            }
            
            combined_system = ""
            if system_parts:
                combined_system = "\n\n".join([p for p in system_parts if p.strip()])
                if combined_system:
                    cleaned_req["system"] = combined_system

            # ──────────────────────────────────────────────────
            #  2a. 智能任务路由 (Smart Router — 方案 B)
            #      Based on conversation content, override model
            #      for optimal task-model fit. Modifies body["model"].
            # ──────────────────────────────────────────────────
            model_name = classify_and_route(body, other_messages, combined_system)

            # Update cleaned_req with the (possibly routed) model
            cleaned_req["model"] = model_name

            # 保留核心参数
            for field in ["max_tokens", "temperature", "stream", "tools", "tool_choice", "thinking", "output_config"]:
                if field in body:
                    cleaned_req[field] = body[field]

            # ──────────────────────────────────────────────────
            #  2b. 动态多渠道路由选择 (Router)
            # ──────────────────────────────────────────────────
            # 判断 CPA 是否已配置 (非空且非默认占位符)
            cpa_url = os.environ.get("CPA_TARGET_URL", "").strip()
            cpa_key = os.environ.get("CPA_API_KEY", "").strip()
            cpa_is_configured = False
            if cpa_url and "your-remote-cpa-endpoint" not in cpa_url:
                if cpa_key and "your-cpa-api-key" not in cpa_key:
                    cpa_is_configured = True
            
            is_openai_route = False
            
            # 如果模型名中包含 sensenova、deepseek-v4-flash 或 gpt，或者 CPA 没有配置，则选择特定配置的模型直连 (SenseNova)
            if "deepseek-v4-flash" in model_name.lower() or "sensenova" in model_name.lower() or "gpt" in model_name.lower() or not cpa_is_configured:
                print(f"[ROUTER] Routing model {model_name} to SenseNova direct endpoint (CPA configured: {cpa_is_configured})...")
                is_openai_route = True
                target_base_url = SENSENOVA_URL
                auth_key = SENSENOVA_KEY
            else:
                # 默认使用 CPA
                print(f"[ROUTER] Routing model {model_name} to remote CPA endpoint...")
                is_openai_route = False
                target_base_url = DEFAULT_CPA_URL
                auth_key = DEFAULT_CPA_KEY

            # ──────────────────────────────────────────────────
            #  3. 请求与协议格式转译 (Format Translator)
            # ──────────────────────────────────────────────────
            if is_openai_route:
                # 转换 Anthropic 格式为 OpenAI completions 格式
                openai_messages = []
                if combined_system:
                    openai_messages.append({"role": "system", "content": combined_system})
                
                for msg in other_messages:
                    role = msg.get("role")
                    content = msg.get("content")
                    
                    if isinstance(content, str):
                        openai_messages.append({"role": role, "content": content})
                    elif isinstance(content, list):
                        tool_results = []
                        tool_uses = []
                        text_parts = []
                        
                        for part in content:
                            if not isinstance(part, dict):
                                if isinstance(part, str):
                                    text_parts.append(part)
                                continue
                            
                            part_type = part.get("type")
                            if part_type == "text":
                                text_parts.append(part.get("text", ""))
                            elif part_type == "tool_result":
                                tool_results.append(part)
                            elif part_type == "tool_use":
                                tool_uses.append(part)
                        
                        if tool_results:
                            text_content = "".join(text_parts).strip()
                            if text_content:
                                openai_messages.append({"role": "user", "content": text_content})
                                
                            for part in tool_results:
                                tool_call_id = part.get("tool_use_id")
                                tc_content = part.get("content", "")
                                if isinstance(tc_content, list):
                                    tc_text = ""
                                    for tc_part in tc_content:
                                        if isinstance(tc_part, dict) and tc_part.get("type") == "text":
                                            tc_text += tc_part.get("text", "")
                                        elif isinstance(tc_part, str):
                                            tc_text += tc_part
                                    tc_content = tc_text
                                    
                                if part.get("is_error"):
                                    tc_content = f"Error: {tc_content}"
                                    
                                openai_messages.append({
                                    "role": "tool",
                                    "tool_call_id": tool_call_id,
                                    "content": str(tc_content)
                                })
                        elif tool_uses:
                            tool_calls = []
                            for part in tool_uses:
                                tool_call_id = part.get("id")
                                tool_name = part.get("name")
                                tool_input = part.get("input", {})
                                if not isinstance(tool_input, str):
                                    tool_input = json.dumps(tool_input)
                                tool_calls.append({
                                    "id": tool_call_id,
                                    "type": "function",
                                    "function": {
                                        "name": tool_name,
                                        "arguments": tool_input
                                    }
                                })
                            text_content = "".join(text_parts).strip()
                            openai_messages.append({
                                "role": "assistant",
                                "content": text_content if text_content else None,
                                "tool_calls": tool_calls
                            })
                        else:
                            text_content = "".join(text_parts)
                            openai_messages.append({"role": role, "content": text_content})
                
                openai_req = {
                    "model": "deepseek-v4-flash",  # 强制映射为 SenseNova 支持的实际模型
                    "messages": openai_messages,
                    "stream": is_stream
                }
                if "temperature" in body:
                    openai_req["temperature"] = body["temperature"]
                if "max_tokens" in body:
                    openai_req["max_tokens"] = body["max_tokens"]
                if "tools" in body:
                    openai_req["tools"] = translate_tools_to_openai(body["tools"])
                if "tool_choice" in body:
                    tc = body["tool_choice"]
                    if isinstance(tc, dict):
                        tc_type = tc.get("type")
                        if tc_type == "auto":
                            openai_req["tool_choice"] = "auto"
                        elif tc_type == "any":
                            openai_req["tool_choice"] = "required"
                        elif tc_type == "tool":
                            openai_req["tool_choice"] = {
                                "type": "function",
                                "function": {"name": tc.get("name")}
                            }
                
                req_data = json.dumps(openai_req).encode("utf-8")
                req_path = "/v1/chat/completions"
            else:
                # 保持 Anthropic 格式直接透传
                req_data = json.dumps(cleaned_req).encode("utf-8")
                req_path = self.path

            # 构建目标 Request 头部
            req_headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {auth_key}"
            }
            if not is_openai_route:
                req_headers["anthropic-version"] = self.headers.get("anthropic-version", "2023-06-01")
            
            if is_stream:
                req_headers["Accept"] = "text/event-stream"
                
            req = urllib.request.Request(
                f"{target_base_url}{req_path}",
                data=req_data,
                headers=req_headers
            )

            # ──────────────────────────────────────────────────
            #  4. 执行请求并流式返回响应 (Streaming Forwarder)
            # ──────────────────────────────────────────────────
            if is_stream:
                try:
                    resp = urllib.request.urlopen(req, timeout=90)
                except urllib.error.HTTPError as e:
                    error_body = e.read().decode("utf-8", errors="replace")
                    if is_quota_error(e.code, error_body):
                        mark_model_failure(model_name)
                        print(f"[QUOTA] {model_name} returned {e.code}, marked unhealthy")
                    self.send_response(e.code)
                    self.end_headers()
                    self.wfile.write(error_body.encode())
                    return
                except Exception as e:
                    import traceback
                    print(f"[ERROR] Exception opening stream request:")
                    traceback.print_exc()
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": str(e)}).encode())
                    return

                # 开启流式 SSE 响应
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                
                # 若是 OpenAI 格式，先向客户端推送 Anthropic 流式握手头部
                if is_openai_route:
                    self.wfile.write(b'event: message_start\ndata: {"type": "message_start", "message": {"id": "msg_local_cleaner", "type": "message", "role": "assistant", "content": [], "model": "' + model_name.encode() + b'", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 0, "output_tokens": 0}}}\n\n')
                    # 不在这里发送 content_block_start，而是在收到第一个 chunk 时动态发送
                    # 这样可以根据是否有 reasoning_content 来决定发送 thinking block 还是 text block
                    self.wfile.flush()
                
                in_thinking = False
                content_started = False
                text_block_index = 0  # 0 if no thinking, 1 if thinking present
                tool_states = {}
                openai_usage = None
                
                with resp:
                    for line in resp:
                        if not line:
                            continue
                        if is_openai_route:
                            # 翻译 OpenAI 流式区块为 Anthropic 流式区块
                            line_str = line.decode("utf-8").strip()
                            if line_str.startswith("data:"):
                                data_part = line_str[5:].strip()
                                if data_part == "[DONE]":
                                    continue
                                try:
                                    chunk_json = json.loads(data_part)
                                    if chunk_json.get("usage"):
                                        openai_usage = chunk_json.get("usage")
                                    choices = chunk_json.get("choices", [])
                                    if choices:
                                        delta = choices[0].get("delta", {})
                                        content_chunk = delta.get("content", "")
                                        reasoning_chunk = delta.get("reasoning_content", "")
                                        
                                        if reasoning_chunk and not content_started:
                                            if not in_thinking:
                                                in_thinking = True
                                                # 发送 thinking content_block_start
                                                thinking_start = {
                                                    "type": "content_block_start",
                                                    "index": 0,
                                                    "content_block": {
                                                        "type": "thinking",
                                                        "thinking": ""
                                                    }
                                                }
                                                self.wfile.write(f"event: content_block_start\ndata: {json.dumps(thinking_start)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                            
                                            # 发送 thinking delta
                                            thinking_delta = {
                                                "type": "content_block_delta",
                                                "index": 0,
                                                "delta": {
                                                    "type": "thinking_delta",
                                                    "thinking": reasoning_chunk
                                                }
                                            }
                                            self.wfile.write(f"event: content_block_delta\ndata: {json.dumps(thinking_delta)}\n\n".encode("utf-8"))
                                            self.wfile.flush()
                                            
                                        elif content_chunk:
                                            content_started = True
                                            if in_thinking:
                                                in_thinking = False
                                                text_block_index = 1
                                                # 关闭 thinking block
                                                thinking_stop = {
                                                    "type": "content_block_stop",
                                                    "index": 0
                                                }
                                                self.wfile.write(f"event: content_block_stop\ndata: {json.dumps(thinking_stop)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                                
                                                # 开启 text block
                                                text_start = {
                                                    "type": "content_block_start",
                                                    "index": 1,
                                                    "content_block": {
                                                        "type": "text",
                                                        "text": ""
                                                    }
                                                }
                                                self.wfile.write(f"event: content_block_start\ndata: {json.dumps(text_start)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                            elif text_block_index == 0 and not any(s["started"] for s in tool_states.values()):
                                                # 第一次收到 content，且没有 thinking，开启 text block
                                                text_start = {
                                                    "type": "content_block_start",
                                                    "index": 0,
                                                    "content_block": {
                                                        "type": "text",
                                                        "text": ""
                                                    }
                                                }
                                                self.wfile.write(f"event: content_block_start\ndata: {json.dumps(text_start)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                            
                                            # 发送 text delta
                                            text_delta = {
                                                "type": "content_block_delta",
                                                "index": text_block_index,
                                                "delta": {
                                                    "type": "text_delta",
                                                    "text": content_chunk
                                                }
                                            }
                                            self.wfile.write(f"event: content_block_delta\ndata: {json.dumps(text_delta)}\n\n".encode("utf-8"))
                                            self.wfile.flush()
                                            
                                        # 处理流式 tool_calls
                                        tool_calls = delta.get("tool_calls", [])
                                        for tc in tool_calls:
                                            tc_idx = tc.get("index", 0)
                                            if tc_idx not in tool_states:
                                                tool_states[tc_idx] = {"id": "", "name": "", "started": False, "accumulated_args": ""}
                                            
                                            state = tool_states[tc_idx]
                                            if tc.get("id"):
                                                state["id"] = tc.get("id")
                                            if tc.get("function", {}).get("name"):
                                                state["name"] = tc.get("function", {}).get("name")
                                                
                                            if state["id"] and state["name"] and not state["started"]:
                                                state["started"] = True
                                                # Tool calls start at index 2 (thinking=0, text=1)
                                                anth_start = {
                                                    "type": "content_block_start",
                                                    "index": 2 + tc_idx,
                                                    "content_block": {
                                                        "type": "tool_use",
                                                        "id": state["id"],
                                                        "name": state["name"],
                                                        "input": {}
                                                    }
                                                }
                                                self.wfile.write(f"event: content_block_start\ndata: {json.dumps(anth_start)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                                
                                            args_delta = tc.get("function", {}).get("arguments", "")
                                            if args_delta:
                                                if not state["started"]:
                                                    state["id"] = state["id"] or f"toolu_fall_{tc_idx}"
                                                    state["name"] = state["name"] or "unknown_tool"
                                                    state["started"] = True
                                                    anth_start = {
                                                        "type": "content_block_start",
                                                        "index": 2 + tc_idx,
                                                        "content_block": {
                                                            "type": "tool_use",
                                                            "id": state["id"],
                                                            "name": state["name"],
                                                            "input": {}
                                                        }
                                                    }
                                                    self.wfile.write(f"event: content_block_start\ndata: {json.dumps(anth_start)}\n\n".encode("utf-8"))
                                                    self.wfile.flush()
                                                
                                                state["accumulated_args"] += args_delta
                                                anth_delta = {
                                                    "type": "content_block_delta",
                                                    "index": 2 + tc_idx,
                                                    "delta": {
                                                        "type": "input_json_delta",
                                                        "partial_json": args_delta
                                                    }
                                                }
                                                self.wfile.write(f"event: content_block_delta\ndata: {json.dumps(anth_delta)}\n\n".encode("utf-8"))
                                                self.wfile.flush()
                                except Exception as chunk_err:
                                    import traceback
                                    print(f"[ERROR] Exception in stream chunk parsing:")
                                    traceback.print_exc()
                        else:
                            # 默认 Anthropic 流直接透传
                            self.wfile.write(line)
                            self.wfile.flush()
                            
                # Stream completed successfully — mark model healthy
                mark_model_success(model_name)

                # 若是 OpenAI 格式，流结束时推送 Anthropic 流收尾事件
                if is_openai_route:
                    # 关闭最后一个 content block
                    if in_thinking:
                        # 关闭 thinking block (index 0)
                        thinking_stop = {
                            "type": "content_block_stop",
                            "index": 0
                        }
                        self.wfile.write(f"event: content_block_stop\ndata: {json.dumps(thinking_stop)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                    else:
                        # 关闭 text block
                        self.wfile.write(f'event: content_block_stop\ndata: {{"type": "content_block_stop", "index": {text_block_index}}}\n\n'.encode("utf-8"))
                        self.wfile.flush()
                    
                    for tc_idx, state in tool_states.items():
                        if state["started"]:
                            anth_stop = {
                                "type": "content_block_stop",
                                "index": 2 + tc_idx
                            }
                            self.wfile.write(f"event: content_block_stop\ndata: {json.dumps(anth_stop)}\n\n".encode("utf-8"))
                            self.wfile.flush()
                            
                    stop_reason = "end_turn"
                    if any(s["started"] for s in tool_states.values()):
                        stop_reason = "tool_use"
                        
                    out_tokens = 0
                    if openai_usage:
                        out_tokens = openai_usage.get("completion_tokens", 0)
                        
                    message_delta = {
                        "type": "message_delta",
                        "delta": {
                            "stop_reason": stop_reason,
                            "stop_sequence": None
                        },
                        "usage": {
                            "output_tokens": out_tokens
                        }
                    }
                    self.wfile.write(f"event: message_delta\ndata: {json.dumps(message_delta)}\n\n".encode("utf-8"))
                    self.wfile.write(b'event: message_stop\ndata: {"type": "message_stop"}\n\n')
                    self.wfile.flush()
            else:
                # 非流式普通请求
                try:
                    with urllib.request.urlopen(req, timeout=90) as resp:
                        resp_data = resp.read()
                        
                        if is_openai_route:
                            # 翻译 OpenAI 响应为 Anthropic 响应
                            openai_res = json.loads(resp_data.decode("utf-8"))
                            choices = openai_res.get("choices", [])
                            
                            anth_content = []
                            stop_reason = "end_turn"
                            
                            if choices:
                                msg_obj = choices[0].get("message", {})
                                content_text = msg_obj.get("content", "") or ""
                                reasoning_text = msg_obj.get("reasoning_content", "") or ""
                                
                                # 如果有 reasoning_content，创建 thinking content block
                                if reasoning_text:
                                    anth_content.append({
                                        "type": "thinking",
                                        "thinking": reasoning_text
                                    })
                                
                                # 添加 text content block
                                if content_text:
                                    anth_content.append({
                                        "type": "text",
                                        "text": content_text
                                    })
                                    
                                openai_tool_calls = msg_obj.get("tool_calls", [])
                                if openai_tool_calls:
                                    stop_reason = "tool_use"
                                    for tc in openai_tool_calls:
                                        args_str = tc.get("function", {}).get("arguments", "{}")
                                        try:
                                            args_dict = json.loads(args_str)
                                        except:
                                            args_dict = {}
                                            
                                        anth_content.append({
                                            "type": "tool_use",
                                            "id": tc.get("id"),
                                            "name": tc.get("function", {}).get("name"),
                                            "input": args_dict
                                        })
                                        
                            if not anth_content:
                                anth_content.append({
                                    "type": "text",
                                    "text": ""
                                })
                                
                            anth_res = {
                                "id": openai_res.get("id", "msg_local_cleaner"),
                                "type": "message",
                                "role": "assistant",
                                "content": anth_content,
                                "model": model_name,
                                "stop_reason": stop_reason,
                                "stop_sequence": None,
                                "usage": {
                                    "input_tokens": openai_res.get("usage", {}).get("prompt_tokens", 0),
                                    "output_tokens": openai_res.get("usage", {}).get("completion_tokens", 0)
                                }
                            }
                            resp_data = json.dumps(anth_res).encode("utf-8")
                            
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(resp_data)))
                        self.end_headers()
                        self.wfile.write(resp_data)
                        mark_model_success(model_name)
                except urllib.error.HTTPError as e:
                    error_body = e.read().decode("utf-8", errors="replace")
                    if is_quota_error(e.code, error_body):
                        mark_model_failure(model_name)
                        print(f"[QUOTA] {model_name} returned {e.code}, marked unhealthy")
                    self.send_response(e.code)
                    self.end_headers()
                    self.wfile.write(error_body.encode())
                
        except Exception as e:
            import traceback
            print(f"[ERROR] Exception in do_POST:")
            traceback.print_exc()
            try:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
            except Exception as write_err:
                print(f"[ERROR] Failed to send 500 response: {write_err}")
            
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')
        
    def log_message(self, format, *args):
        pass

# 启动后台自动发现守护线程
def run_auto_discovery():
    import time
    import subprocess
    import threading
    script_dir = Path(__file__).resolve().parent
    tester_script = script_dir / "test_and_register_models.py"
    
    time.sleep(3)
    
    while True:
        try:
            if tester_script.exists():
                print("[BACKGROUND] Starting automatic CPA model discovery...")
                subprocess.run([sys.executable, str(tester_script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print("[BACKGROUND] Automatic CPA model discovery complete and synced!")
        except Exception as e:
            pass
        time.sleep(7200)

import threading
t = threading.Thread(target=run_auto_discovery, daemon=True)
t.start()

server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), ProxyHandler)
print(f"============================================================")
print(f" CPA 消息清洗本地中间件运行成功！")
print(f" 本地监听端口: http://127.0.0.1:{PORT}")
print(f" 默认 CPA 网关: {DEFAULT_CPA_URL}")
print(f" 增加 SenseNova 动态路由直接支持。")
print(f"============================================================")
sys.stdout.flush()
server.serve_forever()
