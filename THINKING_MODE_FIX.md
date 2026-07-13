# Fix for Thinking Mode (reasoning_content) Issue

## Problem

When using DeepSeek V4 with thinking mode enabled and tool calls, the API returns:
```
API Error: 400 The `reasoning_content` in the thinking mode must be passed back to the API
```

This occurs because:
1. DeepSeek V4 returns `reasoning_content` (thinking process) in addition to `content` (final answer)
2. In multi-turn conversations with tool calls, `reasoning_content` must be passed back to the API
3. The proxy was converting OpenAI's `reasoning_content` to Anthropic's `<thinking>` tags format, which is incompatible

## Solution

Updated the CPA Cleaner proxy (`proxy_cpa_cleaner.py`) to properly handle thinking mode by:

### 1. Streaming Responses

**Before:** Converted `reasoning_content` to `<thinking>` tags in text content
**After:** Creates proper Anthropic `thinking` content blocks:

```python
# Send thinking block start
{"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}

# Send thinking deltas
{"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "..."}}

# Close thinking block, open text block
{"type": "content_block_stop", "index": 0}
{"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}
```

### 2. Non-Streaming Responses

**Before:** Wrapped `reasoning_content` in `<thinking>` tags within text content
**After:** Creates separate content blocks:

```json
{
  "content": [
    {"type": "thinking", "thinking": "..."},
    {"type": "text", "text": "..."},
    {"type": "tool_use", "id": "...", "name": "...", "input": {...}}
  ]
}
```

### 3. Index Management

- Thinking blocks: index 0
- Text blocks: index 1 (if thinking present) or index 0 (if no thinking)
- Tool use blocks: index 2+ (if thinking present) or index 1+ (if no thinking)

### 4. Content Ordering

Ensured proper ordering of content blocks:
1. Thinking block (if present)
2. Text block (if present)
3. Tool use blocks (if present)

## Changes Made

1. **Streaming handshake**: Removed initial text block start, now sends dynamically based on first chunk
2. **Thinking block handling**: Added proper thinking block start/stop/delta events
3. **Text block handling**: Updated to use correct index based on thinking presence
4. **Tool call indices**: Updated to start at index 2 when thinking is present
5. **Content started tracking**: Added flag to prevent thinking blocks after content starts

## Testing

Created `test_thinking_mode.py` to verify:
- Non-streaming thinking block format
- Streaming thinking block format
- Tool calls with thinking blocks

All tests pass successfully.
