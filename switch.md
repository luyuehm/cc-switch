---
description: "List models or switch Claude Code AI model, with CPA endpoint awareness"
argument-hint: "[list | model_name]"
---

As a model switching expert, follow these steps exactly:

## Step 0: CPA Dynamic Detection

**Purpose**: Get the latest model list from the CPA endpoint, compare with local `settings.json`, and automatically detect newly added/deprecated models.

**Conditional execution**:
- If parameters include `--offline` → **skip this step entirely**, use `settings.json` static list only
- If user explicitly requests `--status`, `--compare`, or `--verbose` → execute detection
- If only a model name is provided (e.g. `/switch gpt-5.5`) → **skip detection**, switch directly
- Other cases (`list` / empty params / number) → execute CPA detection normally

### Execution Flow

1. **Read credentials**: From `settings.json` read `env.ANTHROPIC_API_KEY`.

2. **Call CPA endpoint**:
```bash
curl -s "https://<YOUR_CPA_PROXY>/v1/models" \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json"
```

3. **Parse response**: Extract `data[].id` as CPA model IDs, `data[].owned_by` as source, `data[].created` as timestamp.

4. **Compare with local**: Load `availableModels` from `C:\Users\admin\.claude\settings.json`.

5. **Classify**:
   - CPA models NOT in `availableModels` → 🆕 NEW (available to add)
   - Models in `availableModels` NOT in CPA → ⚠️ DEPRECATED (may not work)
   - Models in both → ✅ active

6. **Cache result**: Save comparison to `C:\Users\admin\.claude\.cpa-cache.json`.

## Step 1: Display Model List

Show models in groups:

```
=== CPA Detection Summary ===
🆕 New: <count> models available
⚠️  Deprecated: <count> models may not work
💾 Cache saved

=== Available Models (73) ===
Current: gpt-5.5
Base URL: https://<YOUR_CPA_PROXY>/

[GPT] (7):
  gpt-5.5
  gpt-5.4
  ...

[Claude] (9):
  claude-sonnet-4.6
  claude-opus-4-7
  ...

[Qwen] (12):
  qwen3.6-35b-a3b-nvfp4
  ...

[DeepSeek] (6):
  deepseek-v4-flash
  ...

... (group all models by vendor prefix)

To switch: /switch <model_name>
To add new: /switch --add <model_name>
To remove: /switch --remove <model_name>
For status only: /switch --status
For offline mode: /switch --offline
```

## Step 2: Model Switching

When user provides a model name or number, switch by modifying `settings.json`:

1. **Locate model** in `availableModels` (by name match or index).
2. **Switch all fields**:
   - `env.ANTHROPIC_MODEL`
   - `env.ANTHROPIC_DEFAULT_HAIKU_MODEL`
   - `env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME`
   - `env.ANTHROPIC_DEFAULT_SONNET_MODEL`
   - `env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME`
   - `env.ANTHROPIC_DEFAULT_OPUS_MODEL`
   - `env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME`
   - `env.ANTHROPIC_REASONING_MODEL`
   - `fallbackModel[0]`
   - `model`
3. **Save `settings.json`**.
4. **Report**: `Switched: <old> → <new>  |  Run /reset to apply`

## Commands Reference

| Command | Action |
|---------|--------|
| `/switch` | List all models with CPA detection |
| `/switch gpt-5.5` | Switch to GPT-5.5 |
| `/switch --offline` | List local models only (no network) |
| `/switch --status` | CPA detection summary only |
| `/switch --add <name>` | Add model to availableModels |
| `/switch --remove <name>` | Remove model from availableModels |
