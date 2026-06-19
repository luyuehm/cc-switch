import json
import http.server
import urllib.request
import sys
import os
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
            
            model_name = body.get("model", "")
            is_stream = body.get("stream", False)
            
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
            
            # 保留核心参数
            for field in ["max_tokens", "temperature", "stream", "tools", "tool_choice", "thinking", "output_config"]:
                if field in body:
                    cleaned_req[field] = body[field]

            # ──────────────────────────────────────────────────
            #  2. 动态多渠道路由选择 (Router)
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
                    self.send_response(e.code)
                    self.end_headers()
                    self.wfile.write(e.read())
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
                    self.wfile.write(b'event: content_block_start\ndata: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}\n\n')
                    self.wfile.flush()
                
                in_thinking = False
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
                                        
                                        text_to_send = ""
                                        if reasoning_chunk:
                                            if not in_thinking:
                                                in_thinking = True
                                                text_to_send += "<thinking>\n"
                                            text_to_send += reasoning_chunk
                                        elif content_chunk:
                                            if in_thinking:
                                                in_thinking = False
                                                text_to_send += "\n</thinking>\n\n"
                                            text_to_send += content_chunk
                                            
                                        if text_to_send:
                                            anth_chunk = {
                                                "type": "content_block_delta",
                                                "index": 0,
                                                "delta": {
                                                    "type": "text_delta",
                                                    "text": text_to_send
                                                }
                                            }
                                            self.wfile.write(f"event: content_block_delta\ndata: {json.dumps(anth_chunk)}\n\n".encode("utf-8"))
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
                                                anth_start = {
                                                    "type": "content_block_start",
                                                    "index": 1 + tc_idx,
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
                                                        "index": 1 + tc_idx,
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
                                                    "index": 1 + tc_idx,
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
                            
                # 若是 OpenAI 格式，流结束时推送 Anthropic 流收尾事件
                if is_openai_route:
                    if in_thinking:
                        anth_chunk = {
                            "type": "content_block_delta",
                            "index": 0,
                            "delta": {
                                "type": "text_delta",
                                "text": "\n</thinking>\n\n"
                            }
                        }
                        self.wfile.write(f"event: content_block_delta\ndata: {json.dumps(anth_chunk)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                    self.wfile.write(b'event: content_block_stop\ndata: {"type": "content_block_stop", "index": 0}\n\n')
                    self.wfile.flush()
                    
                    for tc_idx, state in tool_states.items():
                        if state["started"]:
                            anth_stop = {
                                "type": "content_block_stop",
                                "index": 1 + tc_idx
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
                                if reasoning_text:
                                    content_text = f"<thinking>\n{reasoning_text}\n</thinking>\n\n{content_text}"
                                
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
                except urllib.error.HTTPError as e:
                    self.send_response(e.code)
                    self.end_headers()
                    self.wfile.write(e.read())
                
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
