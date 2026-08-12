# cc-switch.sh — Claude Code Model Switcher for macOS (zsh/bash)
# Source: . ./cc-switch.sh   or add to ~/.zshrc
# https://github.com/luyuehm/cc-switch
# v2.4.0 — Health check, CPA auto-discovery, cc-run, cc-config, cc-test

CC_SETTINGS_PATH="$HOME/.claude/settings.json"
CC_ENV_PATH="$HOME/.claude/cc-switch.env"

# ─── In-memory health cache (TTL: 60s) ───
# Format: __cc_health_cache[model]="<epoch_timestamp>:<healthy|unhealthy>"
typeset -A __cc_health_cache 2>/dev/null || true
typeset -i CC_HEALTH_CACHE_TTL=60

__cc_load_env() {
  [[ -f "$CC_ENV_PATH" ]] || return
  # Skip auto-export if CC_SWITCH_SKIP_ENV is set (prevents "Both claude.ai and API_KEY" conflict)
  [[ "${CC_SWITCH_SKIP_ENV:-0}" == "1" ]] && return
  while IFS='=' read -r key val; do
    key="${key#"${key%%[![:space:]]*}"}"
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    export "$key=$val"
  done < "$CC_ENV_PATH"
}

__cc_load_env

__cc_json_get() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

__cc_json_set() {
  local key="$1" val="$2"
  python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = '$key'.split('.')
obj = d
for k in keys[:-1]:
    obj = obj[k]
obj[keys[-1]] = $val
json.dump(d, sys.stdout, indent=2, ensure_ascii=False)
"
}

__cc_find_claude() {
  local cb
  for cb in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
    if [[ -x "$cb" ]] && "$cb" --version 2>&1 | grep -q "Claude Code"; then
      echo "$cb"
      return
    fi
  done
  if command -v claude &>/dev/null; then
    cb="$(command -v claude)"
    if "$cb" --version 2>&1 | grep -q "Claude Code"; then
      echo "claude"
      return
    fi
  fi
  if npx -y @anthropic-ai/claude-code --version &>/dev/null; then
    echo "npx -y @anthropic-ai/claude-code"
    return
  fi
  echo ""
}

__cc_read_settings() {
  if [[ ! -f "$CC_SETTINGS_PATH" ]]; then
    mkdir -p "$(dirname "$CC_SETTINGS_PATH")"
    echo '{"availableModels":[],"env":{}}' > "$CC_SETTINGS_PATH"
  elif ! python3 -c "import json; json.load(open('$CC_SETTINGS_PATH'))" 2>/dev/null; then
    echo '{"availableModels":[],"env":{}}' > "$CC_SETTINGS_PATH"
  fi
  cat "$CC_SETTINGS_PATH"
}

__cc_save_settings() {
  cat > "$CC_SETTINGS_PATH"
}

__cc_get_current_model() {
  local json
  json="$(__cc_read_settings)" || return 1
  echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('env',{}).get('ANTHROPIC_MODEL','(unknown)'))"
}

# ─── CPA Endpoint Resolution ───
# Priority: shell ANTHROPIC_BASE_URL > file CPA_MODELS_URL > ~/.openclaw/.env > settings.json
# Auth: shell ANTHROPIC_AUTH_TOKEN > shell ANTHROPIC_API_KEY > file CPA_API_KEY > ~/.openclaw/.env > settings.json
__cc_resolve_endpoint() {
  local shell_url="${ANTHROPIC_BASE_URL:-}"
  local shell_token="${ANTHROPIC_AUTH_TOKEN:-}"
  local shell_key="${ANTHROPIC_API_KEY:-}"

  local cpa_url=""
  local api_key=""

  # URL resolution
  if [[ -n "$shell_url" ]]; then
    cpa_url="${shell_url%/}/v1/models"
  elif [[ -n "${CPA_MODELS_URL:-}" ]]; then
    cpa_url="$CPA_MODELS_URL"
  else
    # Fallback: read from ~/.openclaw/.env (unified config)
    local openclaw_url=""
    [[ -f "$HOME/.openclaw/.env" ]] && openclaw_url="$(grep '^CLAUDE_CODE_BASE_URL=' "$HOME/.openclaw/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    [[ -n "$openclaw_url" ]] && cpa_url="${openclaw_url%/}/v1/models"
  fi

  # If still empty, try settings.json
  if [[ -z "$cpa_url" ]]; then
    local json
    json="$(__cc_read_settings 2>/dev/null)" || true
    if [[ -n "$json" ]]; then
      local base_url
      base_url="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_BASE_URL','')")"
      [[ -n "$base_url" ]] && cpa_url="${base_url%/}/v1/models"
    fi
  fi

  # API key resolution
  if [[ -n "$shell_token" ]]; then
    api_key="$shell_token"
  elif [[ -n "$shell_key" ]]; then
    api_key="$shell_key"
  elif [[ -n "${CPA_API_KEY:-}" ]]; then
    api_key="$CPA_API_KEY"
  else
    # Fallback: read from ~/.openclaw/.env
    [[ -f "$HOME/.openclaw/.env" ]] && api_key="$(grep '^CPA_API_KEY=' "$HOME/.openclaw/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  fi

  # If still empty, try settings.json
  if [[ -z "$api_key" ]]; then
    local json
    json="$(__cc_read_settings 2>/dev/null)" || true
    if [[ -n "$json" ]]; then
      api_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_AUTH_TOKEN','')")"
      [[ -z "$api_key" ]] && api_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
    fi
  fi

  echo "${cpa_url}|${api_key}"
}

# ─── Health Check ───
# Ping a model via POST /v1/messages to verify it's responsive.
# Uses in-memory cache with 60s TTL.
# Returns 0 if healthy, 1 if unhealthy.
__cc_test_model_health() {
  local model="$1"
  local timeout_sec="${2:-10}"
  local now
  now="$(date +%s)"

  # Check cache
  local cached="${__cc_health_cache[$model]:-}"
  if [[ -n "$cached" ]]; then
    local cache_ts="${cached%%:*}"
    local cache_val="${cached##*:}"
    if (( now - cache_ts < CC_HEALTH_CACHE_TTL )); then
      [[ "$cache_val" == "healthy" ]] && return 0 || return 1
    fi
  fi

  # Resolve endpoint
  local ep_raw
  ep_raw="$(__cc_resolve_endpoint)"
  local api_key="${ep_raw##*|}"
  local cpa_url="${ep_raw%|*}"
  local base_url
  base_url="${ANTHROPIC_BASE_URL:-}"
  [[ -z "$base_url" ]] && base_url="${cpa_url%/v1/models}"

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    __cc_health_cache[$model]="$now:unhealthy"
    return 1
  fi

  local messages_url="${base_url%/}/v1/messages"

  # Use realistic payload to exercise the pipeline
  local body
  body=$(cat <<EOF
{"model":"$model","system":"You are a helpful assistant.","messages":[{"role":"user","content":"ping"}],"max_tokens":5}
EOF
)

  local response
  response="$(curl -s --connect-timeout 5 --max-time "$timeout_sec" \
    -X POST "$messages_url" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "$body" 2>/dev/null)" || {
    __cc_health_cache[$model]="$now:unhealthy"
    return 1
  }

  # Check for hidden error body (some proxies return 200 with error JSON)
  if echo "$response" | grep -qiE '"error"|"overloaded"|"unavailable"'; then
    __cc_health_cache[$model]="$now:unhealthy"
    return 1
  fi

  __cc_health_cache[$model]="$now:healthy"
  return 0
}

# Test candidates in priority order, return first healthy model (sequential early-exit)
__cc_select_healthy_model() {
  local candidates=("$@")
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -z "$candidate" ]] && continue
    local cached="${__cc_health_cache[$candidate]:-}"
    if [[ -n "$cached" ]]; then
      local cache_val="${cached##*:}"
      if [[ "$cache_val" == "healthy" ]]; then
        echo "$candidate"
        return 0
      fi
      continue  # known unhealthy, skip
    fi
    echo -n "." >&2
    if __cc_test_model_health "$candidate" 10; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# ─── CPA Model Fetch ───
__cc_fetch_cpa_models() {
  local ep_raw
  ep_raw="$(__cc_resolve_endpoint)"
  local api_key="${ep_raw##*|}"
  local cpa_url="${ep_raw%|*}"

  [[ -z "$cpa_url" || -z "$api_key" ]] && return 1

  local response
  response="$(curl -s --connect-timeout 5 --max-time 15 "$cpa_url" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json")" || return 1

  echo "$response" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if isinstance(d, dict) and 'data' in d:
        models=[m['id'] for m in d['data'] if m.get('id')]
    elif isinstance(d, list):
        models=[m.get('id','') for m in d if m.get('id')]
    else:
        models=[]
    for m in sorted(models):
        print(m)
except Exception as e:
    sys.exit(1)
" 2>/dev/null
}

# ─── Model Categorization (Python helper, used by __cc_auto_assign and menu) ───
__cc_categorize_models_py() {
  python3 -c "
import sys
models = [l.strip() for l in sys.stdin if l.strip()]

def get_cat(m):
    if m.startswith('gpt-') or m.startswith('o'): return 'GPT'
    if m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'): return 'Claude'
    if m.startswith('deepseek'): return 'DeepSeek'
    if m.startswith('qwen'): return 'Qwen'
    if m.startswith('grok'): return 'Grok'
    if m.startswith('kimi') or m.startswith('moonshot'): return 'Moonshot'
    if m.startswith('llama'): return 'Llama'
    if m.startswith('mistral') or m.startswith('mixtral'): return 'Mistral'
    if m.startswith('gemin'): return 'Gemini'
    if 'step' in m.lower(): return 'Stepfun'
    return 'Other'

groups = {}
for m in models:
    cat = get_cat(m)
    groups.setdefault(cat, []).append(m)

for cat in sorted(groups):
    for m in sorted(groups[cat]):
        print(f'{cat}|{m}')
"
}

# ─── CPA Auto Discovery & Task Assignment ───
# Two-phase health verification: sequential probing + final re-ping
__cc_auto_assign() {
  local cpa_models
  cpa_models="$(__cc_fetch_cpa_models 2>/dev/null)" || true

  if [[ -z "$cpa_models" ]]; then
    local json
    json="$(__cc_read_settings)" || return 1
    cpa_models="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
")"
  fi

  [[ -z "$cpa_models" ]] && { echo "[!] No models available from CPA or local list." >&2; return 1; }

  # Clear stale cache entries
  local now
  now="$(date +%s)"
  local cutoff=$(( now - CC_HEALTH_CACHE_TTL ))
  for k in "${(@k)__cc_health_cache}"; do
    local ts="${__cc_health_cache[$k]%%:*}"
    (( ts < cutoff )) && unset "__cc_health_cache[$k]"
  done

  # Categorize models
  local categorized
  categorized="$(echo "$cpa_models" | __cc_categorize_models_py)"

  # Build category arrays (filter out "free" models for paid preference)
  local claude_models=() gpt_models=() ds_models=() qwen_models=() grok_models=() image_models=() all_models=()
  local claude_paid=() gpt_paid=() ds_paid=() qwen_paid=()

  while IFS='|' read -r cat model; do
    all_models+=("$model")
    case "$cat" in
      Claude)  claude_models+=("$model"); [[ "$model" != *free* ]] && claude_paid+=("$model") ;;
      GPT)     gpt_models+=("$model");    [[ "$model" != *free* ]] && gpt_paid+=("$model") ;;
      DeepSeek) ds_models+=("$model");    [[ "$model" != *free* ]] && ds_paid+=("$model") ;;
      Qwen)    qwen_models+=("$model");   [[ "$model" != *free* ]] && qwen_paid+=("$model") ;;
      Grok)    grok_models+=("$model") ;;
    esac
    [[ "$model" == *image* ]] && image_models+=("$model")
  done <<< "$categorized"

  # Limit "anything" fallback to first 20 models
  local all_fallback=("${all_models[@]:0:20}")

  # Use paid versions; fall back to all if paid list is empty
  [[ ${#claude_paid[@]} -eq 0 ]] && claude_paid=("${claude_models[@]}")
  [[ ${#gpt_paid[@]} -eq 0 ]]    && gpt_paid=("${gpt_models[@]}")
  [[ ${#ds_paid[@]} -eq 0 ]]     && ds_paid=("${ds_models[@]}")
  [[ ${#qwen_paid[@]} -eq 0 ]]   && qwen_paid=("${qwen_models[@]}")

  echo -n "  Probing model health" >&2

  local -A assign
  local selected

  # Phase 1: Sequential per-group probing
  # code: Claude (non-haiku) → Claude → GPT → Qwen → anything
  local code_candidates=()
  for m in "${claude_paid[@]}"; do [[ "$m" != *haiku* ]] && code_candidates+=("$m"); done
  code_candidates+=("${claude_paid[@]}")
  code_candidates+=("${gpt_paid[@]}")
  code_candidates+=("${qwen_paid[@]}")
  code_candidates+=("${all_fallback[@]}")
  selected="$(__cc_select_healthy_model "${code_candidates[@]}")" && assign[code]="$selected"

  # reason: GPT sol/reasoning → GPT → Qwen Plus/Max → Claude thinking → Claude → anything
  local reason_candidates=()
  for m in "${gpt_paid[@]}"; do echo "$m" | grep -qE "sol|reason|preview|thinking" && reason_candidates+=("$m"); done
  reason_candidates+=("${gpt_paid[@]}")
  for m in "${qwen_paid[@]}"; do echo "$m" | grep -qE "plus|max|preview" && reason_candidates+=("$m"); done
  reason_candidates+=("${qwen_paid[@]}")
  for m in "${claude_paid[@]}"; do echo "$m" | grep -q "thinking" && reason_candidates+=("$m"); done
  reason_candidates+=("${claude_paid[@]}")
  reason_candidates+=("${all_fallback[@]}")
  selected="$(__cc_select_healthy_model "${reason_candidates[@]}")" && assign[reason]="$selected"

  # quick: DeepSeek flash → DeepSeek → GPT mini/flash → Qwen flash → Grok → anything
  local quick_candidates=()
  for m in "${ds_paid[@]}"; do echo "$m" | grep -q "flash" && quick_candidates+=("$m"); done
  quick_candidates+=("${ds_paid[@]}")
  for m in "${gpt_paid[@]}"; do echo "$m" | grep -qE "mini|flash|turbo|light|lite" && quick_candidates+=("$m"); done
  quick_candidates+=("${gpt_paid[@]}")
  for m in "${qwen_paid[@]}"; do echo "$m" | grep -qE "flash|turbo|light" && quick_candidates+=("$m"); done
  quick_candidates+=("${qwen_paid[@]}")
  quick_candidates+=("${grok_models[@]}")
  quick_candidates+=("${all_fallback[@]}")
  selected="$(__cc_select_healthy_model "${quick_candidates[@]}")" && assign[quick]="$selected"

  # image: image-specific → GPT → Grok image → anything
  local image_candidates=()
  image_candidates+=("${image_models[@]}")
  image_candidates+=("${gpt_paid[@]}")
  for m in "${grok_models[@]}"; do echo "$m" | grep -q "image" && image_candidates+=("$m"); done
  image_candidates+=("${all_fallback[@]}")
  selected="$(__cc_select_healthy_model "${image_candidates[@]}")" && assign[image]="$selected"

  # default: GPT → DeepSeek → Claude → Qwen → anything
  local default_candidates=()
  default_candidates+=("${gpt_paid[@]}")
  default_candidates+=("${ds_paid[@]}")
  default_candidates+=("${claude_paid[@]}")
  default_candidates+=("${qwen_paid[@]}")
  default_candidates+=("${all_fallback[@]}")
  selected="$(__cc_select_healthy_model "${default_candidates[@]}")" && assign[default]="$selected"

  # Phase 2: Final verification — re-ping each assigned model (bypass cache)
  local task
  for task in code reason quick image default; do
    local model="${assign[$task]:-}"
    [[ -z "$model" ]] && continue
    echo -n "!" >&2
    unset "__cc_health_cache[$model]"
    if ! __cc_test_model_health "$model" 10; then
      echo "" >&2
      echo "  [FALLBACK]  $model unhealthy for '$task', searching..." >&2
      # Build fallback candidates for this task
      local fallback_candidates=()
      case "$task" in
        code)    fallback_candidates=("${code_candidates[@]}") ;;
        reason)  fallback_candidates=("${reason_candidates[@]}") ;;
        quick)   fallback_candidates=("${quick_candidates[@]}") ;;
        image)   fallback_candidates=("${image_candidates[@]}") ;;
        default) fallback_candidates=("${default_candidates[@]}") ;;
      esac
      local new_selected=""
      for m in "${fallback_candidates[@]}"; do
        [[ "$m" == "$model" ]] && continue
        echo -n "." >&2
        if __cc_test_model_health "$m" 10; then
          new_selected="$m"
          break
        fi
      done
      if [[ -n "$new_selected" ]]; then
        echo "    → $new_selected" >&2
        assign[$task]="$new_selected"
      else
        echo "    → No healthy fallback" >&2
        unset "assign[$task]"
      fi
    fi
  done

  echo " [done]" >&2

  # Phase 3: Hard guard — abort if all tasks lost
  if [[ ${#assign[@]} -eq 0 ]]; then
    echo "[!] No healthy models found at all. Settings NOT saved." >&2
    echo "  Check your CPA proxy or API key: ~/.claude/cc-switch.env" >&2
    echo "  Then run 'cc' again." >&2
    return 1
  fi

  local total="${#assign[@]}"
  local total_str=""
  (( total < 5 )) && total_str=" ($total/5 tasks assigned)"
  echo "  All $total assigned models verified healthy$total_str" >&2

  # Save to settings.json
  local json
  json="$(__cc_read_settings)" || return 1

  # Build taskModels JSON
  local tm_json="{"
  local first=1
  for task in code reason quick image default; do
    local m="${assign[$task]:-}"
    if [[ -n "$m" ]]; then
      [[ $first -eq 0 ]] && tm_json+=","
      tm_json+="\"$task\": \"$m\""
      first=0
    fi
  done
  tm_json+="}"

  # Update availableModels with CPA list and save taskModels
  json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cpa_list='''$cpa_models'''
models=[m.strip() for m in cpa_list.split('\n') if m.strip()]
d['availableModels']=sorted(set(models))
d['taskModels']=$tm_json
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
  echo "$json" | __cc_save_settings

  # Return assignments for display
  for task in code reason quick image default; do
    [[ -n "${assign[$task]:-}" ]] && echo "${task}|${assign[$task]}"
  done
  return 0
}

# === MODEL CATEGORIZATION HELPER (shared Python snippet) ===
# Usage: echo '<each-model-on-separate-line>' | __cc_categorize_models [--verbose]
# --verbose: bracket format (e.g. "[GPT]:\n    model1\n    model2")
# default: compact format (e.g. "GPT: model1  model2")
__cc_categorize_models() {
  local verbose=0
  [[ "$1" == "--verbose" ]] && verbose=1
  python3 -c "
import sys
models = [l.strip() for l in sys.stdin if l.strip()]

def get_cat(m):
    if m.startswith('gpt-') or m.startswith('o'): return 'GPT'
    if m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'): return 'Claude'
    if m.startswith('deepseek'): return 'DeepSeek'
    if m.startswith('qwen'): return 'Qwen'
    if m.startswith('grok'): return 'Grok'
    if m.startswith('kimi') or m.startswith('moonshot'): return 'Moonshot'
    if m.startswith('llama'): return 'Llama'
    if m.startswith('mistral') or m.startswith('mixtral'): return 'Mistral'
    if m.startswith('gemin'): return 'Gemini'
    if 'step' in m.lower(): return 'Stepfun'
    return 'Other'

cats = {}
for m in models:
    cat = get_cat(m)
    cats.setdefault(cat, []).append(m)

order = {'GPT':1,'Claude':2,'DeepSeek':3,'Grok':4,'Qwen':5,'Gemini':6,'Moonshot':7,'Llama':8,'Mistral':9,'Stepfun':10,'Other':99}
verbose = $verbose
for cat in sorted(cats.keys(), key=lambda c: order.get(c,99)):
    if verbose:
        print(f'  [{cat}]')
        for m in sorted(cats[cat]):
            print(f'    {m}')
    else:
        print(f'{cat}: ' + '  '.join(sorted(cats[cat])))
"
}

# === MAIN COMMAND ===
# NOTE: If ~/.zshrc has a custom cc() wrapper that delegates to ccx,
# this function will be overridden after sourcing. The ccx-compatible
# cc() uses __cc_test_model_health for pre-switch health checks.
# All other cc-* commands (cc-run, cc-config, cc-test, etc.) work regardless.
cc() {
  local model="${1:-}"

  # No args: CPA auto-discovery + menu
  if [[ -z "$model" ]]; then
    echo "Auto-discovering CPA models..."
    local assignments
    assignments="$(__cc_auto_assign 2>&1)" || true
    if [[ -n "$assignments" ]]; then
      echo ""
      echo "=== Auto Model Assignment ==="
      while IFS='|' read -r task m; do
        printf "  %-8s → %s\n" "$task" "$m"
      done <<< "$assignments"
      echo ""
      echo "  Use 'cc-run <task>' to launch with the assigned model."
      echo "  Use 'cc-config' to view or override these assignments."
      echo ""
    else
      echo " [skip]"
    fi
    __cc_show_menu
    return
  fi

  local json
  json="$(__cc_read_settings)" || return 1

  # Health-check the model BEFORE switching
  echo -n "Probing $model..."
  unset "__cc_health_cache[$model]"
  if ! __cc_test_model_health "$model" 10; then
    echo " [unhealthy]"
    echo "[!]  $model is not responding. Switch cancelled."
    echo "  Try: cc (no args) to auto-assign a healthy model"
    echo "  Or:  cc-test           to list healthy models"
    return 1
  fi
  echo " [ok]"

  local found
  found="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
models=d.get('availableModels',[])
if not models or '$model' in models:
    print('yes')
else:
    print('no')
")"

  if [[ "$found" != "yes" ]]; then
    echo "Adding '$model' to availableModels..."
  fi

  local old_model
  old_model="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_MODEL','(none)')")"

  json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
model='$model'
for k in ['ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME',
          'ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL_NAME',
          'ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL_NAME',
          'ANTHROPIC_REASONING_MODEL']:
    d['env'][k]=model
d['fallbackModel']=[model]
d['model']=model
existing=set(d.get('availableModels',[]))
existing.add(model)
d['availableModels']=sorted(existing)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"

  echo "$json" | __cc_save_settings

  echo "OK: Model switched"
  echo "  Old: $old_model"
  echo "  New: $model"
  echo ""

  local claude_bin
  claude_bin="$(__cc_find_claude)"
  if [[ -z "$claude_bin" ]]; then
    echo "Error: claude not found. Install with: npm install -g @anthropic-ai/claude-code" >&2
    return 1
  fi

  echo "Launching Claude Code (API key auth)..."
  echo ""

  CC_SWITCH_SKIP_ENV=0 __cc_load_env

  local auth_key=""
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    auth_key="$ANTHROPIC_AUTH_TOKEN"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth_key="$ANTHROPIC_API_KEY"
  else
    auth_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_AUTH_TOKEN','')")"
    [[ -z "$auth_key" ]] && auth_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
  fi

  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    export ANTHROPIC_BASE_URL
  else
    local fallback_url
    fallback_url="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_BASE_URL','')")"
    [[ -n "$fallback_url" ]] && export ANTHROPIC_BASE_URL="$fallback_url"
  fi

  if [[ -n "$auth_key" ]]; then
    unset ANTHROPIC_API_KEY
    export ANTHROPIC_AUTH_TOKEN="$auth_key"
  fi

  eval "$claude_bin"
}

# === TASK-SMART LAUNCH ===
# Launch Claude Code with task-optimized model from settings.json.taskModels.
# Health-aware: always does a fresh probe; falls back by same-category then anything.
cc-run() {
  local task="${1:-default}"

  local json
  json="$(__cc_read_settings)" || return 1

  # Read task-model map from settings.json
  local model=""
  if echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict) and '$task' in tm:
    print(tm['$task'])
" 2>/dev/null | grep -q .; then
    model="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['taskModels']['$task'])
")"
  fi

  if [[ -z "$model" ]]; then
    # No taskModels configured — run auto-assign first.
    # Progress dots go to stderr in real-time. stdout (assignments) is discarded
    # but saved to settings.json by __cc_auto_assign itself.
    echo "[cc-run] No taskModels configured. Probing models (dots = one probe):"
    __cc_auto_assign >/dev/null || true
    json="$(__cc_read_settings)" || return 1
    model="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict) and '$task' in tm:
    print(tm['$task'])
else:
    print('')
")"
    if [[ -z "$model" ]]; then
      echo "[cc-run] Could not auto-assign models."
      return 1
    fi
  fi

  echo "[cc-run] Task '$task' → model: $model"

  # Always do a fresh health probe (bypass cache)
  unset "__cc_health_cache[$model]"
  if ! __cc_test_model_health "$model" 10; then
    echo "[cc-run] Model '$model' is not responding. Searching for healthy fallback..."
    # Try same-category models first
    local cat
    cat="$(echo "$model" | python3 -c "
import sys
m=sys.stdin.read().strip()
if m.startswith('gpt-') or m.startswith('o'): print('GPT')
elif m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'): print('Claude')
elif m.startswith('deepseek'): print('DeepSeek')
elif m.startswith('qwen'): print('Qwen')
elif m.startswith('grok'): print('Grok')
else: print('Other')
")"
    local fallback=""
    local models_list
    models_list="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
")"
    # Same category first
    while IFS= read -r m; do
      local mcat
      mcat="$(echo "$m" | python3 -c "
import sys
m=sys.stdin.read().strip()
if m.startswith('gpt-') or m.startswith('o'): print('GPT')
elif m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'): print('Claude')
elif m.startswith('deepseek'): print('DeepSeek')
elif m.startswith('qwen'): print('Qwen')
elif m.startswith('grok'): print('Grok')
else: print('Other')
")"
      [[ "$m" == "$model" ]] && continue
      [[ "$mcat" != "$cat" ]] && continue
      unset "__cc_health_cache[$m]"
      if __cc_test_model_health "$m" 5; then fallback="$m"; break; fi
    done <<< "$models_list"
    # Any category
    if [[ -z "$fallback" ]]; then
      while IFS= read -r m; do
        [[ "$m" == "$model" ]] && continue
        unset "__cc_health_cache[$m]"
        if __cc_test_model_health "$m" 5; then fallback="$m"; break; fi
      done <<< "$models_list"
    fi
    if [[ -n "$fallback" ]]; then
      echo "[cc-run] Fallback to: $fallback"
      model="$fallback"
    else
      echo "[cc-run] No healthy fallback found. Attempting launch anyway..."
    fi
  fi

  cc "$model"
}

# === SHORTCUTS (task-model aware) ===
cc-pro() {
  local model=""
  local json
  json="$(__cc_read_settings 2>/dev/null)" || true
  [[ -n "$json" ]] && model="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print(tm.get('code','claude-opus-4-7'))
")"
  echo "Switching to ${model:-claude-opus-4-7} (code task)..."
  cc "${model:-claude-opus-4-7}"
}

cc-fast() {
  local model=""
  local json
  json="$(__cc_read_settings 2>/dev/null)" || true
  [[ -n "$json" ]] && model="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print(tm.get('quick','deepseek-v4-flash'))
")"
  echo "Switching to ${model:-deepseek-v4-flash} (quick task)..."
  cc "${model:-deepseek-v4-flash}"
}

cc-default() {
  local model=""
  local json
  json="$(__cc_read_settings 2>/dev/null)" || true
  [[ -n "$json" ]] && model="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print(tm.get('default','gpt-5.5'))
")"
  echo "Restoring ${model:-gpt-5.5} (default task)..."
  cc "${model:-gpt-5.5}"
}

# === TASK CONFIGURATION ===
cc-config() {
  local task="${1:-}"
  local model="${2:-}"
  local reset=0
  [[ "$task" == "-Reset" || "$task" == "--reset" ]] && { reset=1; task=""; }

  local json
  json="$(__cc_read_settings)" || return 1

  if [[ "$reset" -eq 1 ]]; then
    echo "Re-running CPA auto-discovery..."
    __cc_auto_assign >/dev/null 2>&1 || {
      echo "Error: could not auto-discover models."
      return 1
    }
    echo ""
    echo "=== Auto Model Assignment ==="
    json="$(__cc_read_settings)" || return 1
    echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict):
    for t in ['code','quick','reason','image','default']:
        if t in tm:
            print(f'  {t:8} → {tm[t]}')
"
    echo ""
    echo "Done. Use 'cc-run <task>' to launch."
    return 0
  fi

  if [[ -n "$task" && -n "$model" ]]; then
    # Validate model exists
    local found
    found="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
models=d.get('availableModels',[])
print('yes' if '$model' in models else 'no')
")"
    if [[ "$found" != "yes" ]]; then
      echo "Error: '$model' not in availableModels" >&2
      return 1
    fi
    json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'taskModels' not in d or not isinstance(d.get('taskModels'),dict):
    d['taskModels']={}
d['taskModels']['$task']='$model'
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
    echo "$json" | __cc_save_settings
    echo "[OK]  Task '$task' → $model"
    echo "  Use 'cc-run $task' to launch with this model."
    return 0
  fi

  # Show current assignments
  local has_tm
  has_tm="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print('yes' if isinstance(tm,dict) and tm else 'no')
")"
  if [[ "$has_tm" != "yes" ]]; then
    echo "No task model assignments configured."
    echo "Run 'cc' (no arguments) for auto-discovery, or use:"
    echo "  cc-config -Reset"
    return 0
  fi

  echo ""
  echo "=== Task Model Assignments ==="
  echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict):
    for t in ['code','quick','reason','image','default']:
        if t in tm:
            print(f'  {t:8} → {tm[t]}')
"
  echo ""
  echo "Override:"
  echo "  cc-config <task> <model>      Set specific model for a task"
  echo "  cc-config -Reset              Re-run CPA auto-discovery"
}

# === MODEL HEALTH TESTING ===
cc-test() {
  local remove_dead=0
  local timeout_sec=10
  local parallel=5

  for arg in "$@"; do
    case "$arg" in
      -RemoveDead|--remove-dead) remove_dead=1 ;;
      -Timeout|--timeout) timeout_sec="${2:-10}"; shift ;;
      -Parallel|--parallel) parallel="${2:-5}"; shift ;;
    esac
    shift 2>/dev/null || true
  done

  local json
  json="$(__cc_read_settings)" || return 1

  local models
  models="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
")"

  local total=0 healthy=0 quota=0 failed=0
  local failed_models=()

  echo ""
  echo "=== Model Health Test ==="
  echo "  Testing $(( $(echo "$models" | wc -l | tr -d ' ') )) models (timeout: ${timeout_sec}s)..."
  echo ""

  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    total=$((total + 1))
    echo -n "  [$total] $model ... "
    unset "__cc_health_cache[$model]"
    if __cc_test_model_health "$model" "$timeout_sec"; then
      echo "[OK]"
      healthy=$((healthy + 1))
    else
      # Distinguish quota vs generic failure by checking response
      local ep_raw base_url api_key
      ep_raw="$(__cc_resolve_endpoint)"
      api_key="${ep_raw##*|}"
      base_url="${ANTHROPIC_BASE_URL:-}"
      [[ -z "$base_url" ]] && base_url="${ep_raw%|*}"
      base_url="${base_url%/v1/models}"
      local body="{\"model\":\"$model\",\"system\":\"You are a helpful assistant.\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":5}"
      local resp
      resp="$(curl -s --connect-timeout 5 --max-time 5 -X POST "${base_url%/}/v1/messages" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null || true)"
      if echo "$resp" | grep -qiE "quota|429|402|insufficient|balance"; then
        echo "[QUOTA]"
        quota=$((quota + 1))
      else
        echo "[FAIL]"
        failed=$((failed + 1))
        failed_models+=("$model")
      fi
    fi
  done <<< "$models"

  echo ""
  echo "=== Results ==="
  echo "  Total   : $total"
  echo "  Healthy : $healthy"
  echo "  Quota   : $quota"
  echo "  Failed  : $failed"

  if [[ "$remove_dead" -eq 1 && ${#failed_models[@]} -gt 0 ]]; then
    echo ""
    echo "Removing ${#failed_models[@]} failed models..."
    local remove_list=""
    for m in "${failed_models[@]}"; do
      remove_list+="$m"$'\n'
    done
    json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
remove_set=set('''$remove_list'''.strip().split('\n'))
d['availableModels']=[m for m in d.get('availableModels',[]) if m not in remove_set]
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
    echo "$json" | __cc_save_settings
    echo "Done. Run 'cc-sync' to re-fetch from CPA."
  fi

  echo ""
  echo "Tip: cc-test -RemoveDead    Remove failed models"
}

# === CPA SYNC ===
cc-sync() {
  local list_mode=0 force=0 remove=0 reassign=0

  for arg in "$@"; do
    case "$arg" in
      -List|--list) list_mode=1 ;;
      -Force|--force) force=1 ;;
      -Remove|--remove) remove=1 ;;
      -Reassign|--reassign) reassign=1 ;;
    esac
  done

  # Use unified endpoint resolver
  local ep_raw
  ep_raw="$(__cc_resolve_endpoint)"
  local api_key="${ep_raw##*|}"
  local cpa_url="${ep_raw%|*}"

  if [[ -z "$cpa_url" || -z "$api_key" ]]; then
    echo "Error: CPA_MODELS_URL or API key not configured." >&2
    echo "  Set in ~/.openclaw/.env (recommended):" >&2
    echo "    CLAUDE_CODE_BASE_URL=http://127.0.0.1:8317" >&2
    echo "    CPA_API_KEY=<your-cpa-key>" >&2
    echo "  Or set in ~/.claude/cc-switch.env:" >&2
    echo "    CPA_MODELS_URL and ANTHROPIC_API_KEY" >&2
    return 1
  fi

  echo "Fetching models from CPA..."
  echo "  $cpa_url"

  local response
  response="$(curl -s --connect-timeout 5 --max-time 15 "$cpa_url" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json")" || {
    echo "Error fetching CPA models: curl failed" >&2
    return 1
  }

  local cpa_models
  cpa_models="$(echo "$response" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if isinstance(d, dict) and 'data' in d:
        models=[m['id'] for m in d['data'] if m.get('id')]
    elif isinstance(d, list):
        models=[m.get('id','') for m in d if m.get('id')]
    else:
        models=[]
    for m in sorted(models):
        print(m)
except Exception as e:
    sys.exit(1)
")" || {
    echo "Error: unexpected CPA response format." >&2
    return 1
  }

  local count
  count="$(echo "$cpa_models" | wc -l | tr -d ' ')"
  echo "  Got $count models from CPA"

  if [[ "$list_mode" -eq 1 ]]; then
    echo ""
    echo "=== CPA Models ($count) ==="
    echo "$cpa_models" | while IFS= read -r m; do echo "  $m"; done
    echo ""
    echo "--- $count models ---"
    return 0
  fi

  local json
  json="$(__cc_read_settings)" || return 1

  local local_models
  local_models="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[])):
    print(m)
")"

  local new_models=""
  local gone_models=""

  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if ! echo "$local_models" | grep -Fxq "$m"; then
      new_models="$new_models$m"$'\n'
    fi
  done <<< "$cpa_models"

  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if ! echo "$cpa_models" | grep -Fxq "$m"; then
      gone_models="$gone_models$m"$'\n'
    fi
  done <<< "$local_models"

  local new_count="$(echo "$new_models" | sed '/^$/d' | wc -l | tr -d ' ')"
  local gone_count="$(echo "$gone_models" | sed '/^$/d' | wc -l | tr -d ' ')"

  echo ""
  echo "=== CPA Sync Report ==="
  echo "  CPA total : $count"
  local local_count="$(echo "$local_models" | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "  Local     : $local_count"
  [[ "$new_count" -gt 0 ]] && echo "  New       : +$new_count (not yet in local)"
  [[ "$gone_count" -gt 0 ]] && echo "  Gone      : -$gone_count (removed from CPA)"

  echo ""
  echo "=== CPA Model List ==="

  echo "$cpa_models" | __cc_categorize_models --verbose

  echo ""
  echo -n "Press Enter to continue, or type 'q' to cancel sync: "
  read -r choice
  if [[ "$choice" == "q" ]]; then
    echo "Sync cancelled."
    return 0
  fi

  if [[ -n "$(echo "$new_models" | sed '/^$/d')" ]]; then
    echo ""
    echo "New models available:"
    echo "$new_models" | sed '/^$/d' | while IFS= read -r m; do echo "  + $m"; done

    local add=0
    if [[ "$force" -eq 1 ]]; then
      add=1
    else
      echo ""
      echo -n "Add these to local list? [Y/n] "
      read -r choice
      add=1
      [[ "$choice" == "n" || "$choice" == "N" ]] && add=0
    fi

    if [[ "$add" -eq 1 ]]; then
      json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
new_models='''$new_models'''
existing=set(d.get('availableModels',[]))
for m in new_models.split('\n'):
    m=m.strip()
    if m:
        existing.add(m)
d['availableModels']=sorted(existing)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      echo "$json" | __cc_save_settings
      local merged_count="$(echo "$json" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('availableModels',[])))")"
      echo "Updated: $local_count -> $merged_count models"
    else
      echo "Skipped. Use 'cc-sync --force' to auto-add."
    fi
  fi

  if [[ -n "$(echo "$gone_models" | sed '/^$/d')" ]]; then
    echo ""
    echo "Models removed from CPA (still in local):"
    echo "$gone_models" | sed '/^$/d' | while IFS= read -r m; do echo "  - $m"; done

    if [[ "$remove" -eq 1 ]]; then
      json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cpa_models='''$cpa_models'''
cpa_set=set(m.strip() for m in cpa_models.split('\n') if m.strip())
local=d.get('availableModels',[])
d['availableModels']=sorted(m for m in local if m in cpa_set)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      echo "$json" | __cc_save_settings
      local cleaned_count="$(echo "$json" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('availableModels',[])))")"
      echo "Cleaned: $local_count -> $cleaned_count models"
    else
      echo "To remove: cc-sync --remove"
    fi
  fi

  if [[ "$new_count" -eq 0 && "$gone_count" -eq 0 ]]; then
    echo "  Status: fully in sync"
  fi

  # Handle -Reassign
  if [[ "$reassign" -eq 1 ]]; then
    echo ""
    echo "Re-assigning task models..."
    __cc_auto_assign >/dev/null 2>&1 || echo "  [skip] Auto-assign failed"
  fi

  echo ""
  echo "Tip: cc-sync --list      -- show full model list only"
  echo "Tip: cc-sync --force     -- auto-add new models"
  echo "Tip: cc-sync --remove    -- remove obsolete models"
  echo "Tip: cc-sync --reassign  -- sync + reassign task models"
}

# === SKILL MENU MANAGEMENT ===
cc-audit() {
  echo "==============================================="
  echo "  Claude Code Menu Audit Report"
  echo "==============================================="
  echo ""

  echo "== Custom Slash Commands (commands/) ===="
  local commands_dir="$HOME/.claude/commands"
  if [[ -d "$commands_dir" ]]; then
    local files=("$commands_dir"/*.md)
    if [[ -f "${files[0]}" ]]; then
      for f in "$commands_dir"/*.md; do
        local desc=""
        desc="$(head -10 "$f" | grep "^description:" | sed 's/^description: *//;s/"//g')"
        echo "  [OK]  /$(basename "$f" .md) — $desc"
      done
    else
      echo "  (none)"
    fi
  else
    echo "  (commands dir not found)"
  fi
  echo ""

  echo "== Hidden Skills (skillOverrides) ===="
  local json
  json="$(__cc_read_settings 2>/dev/null)" || true
  if [[ -n "$json" ]]; then
    local has_hidden
    has_hidden="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ov=d.get('skillOverrides',{})
if isinstance(ov,dict) and ov:
    for k,v in ov.items():
        print(f'{k} -> {v}')
else:
    print('none')
")"
    if [[ "$has_hidden" == "none" ]]; then
      echo "  (none)"
    else
      echo "$has_hidden" | while IFS= read -r line; do echo "  [HIDDEN]  $line"; done
    fi
  else
    echo "  (none)"
  fi
  echo ""

  local cmd_count=0
  [[ -d "$commands_dir" ]] && cmd_count="$(ls "$commands_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  echo "Total: $cmd_count custom commands"
}

cc-hide() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: cc-hide <skill-name|plugin:*>"
    return
  fi

  local json
  json="$(__cc_read_settings)" || return 1

  json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
name='$name'
if 'skillOverrides' not in d or not isinstance(d['skillOverrides'], dict):
    d['skillOverrides']={}
d['skillOverrides'][name]='off'
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
  echo "$json" | __cc_save_settings
  echo "[HIDDEN]  $name"
}

cc-show() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Usage: cc-show <skill-name|plugin:*>"
    return
  fi

  local json
  json="$(__cc_read_settings)" || return 1

  json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
name='$name'
ov=d.get('skillOverrides',{})
if isinstance(ov,dict) and name in ov:
    del ov[name]
    d['skillOverrides']=ov
    json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
    print('REMOVED')
else:
    print('NOT_FOUND')
")"

  if echo "$json" | grep -q "^REMOVED$"; then
    echo "$json" | head -n -1 | __cc_save_settings
    echo "[OK]  Restored: $name"
  else
    echo "[!]   $name is not hidden."
  fi
}

cc-profile() {
  local name="${1:-default}"

  local json
  json="$(__cc_read_settings)" || return 1

  case "$name" in
    default)
      json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d.pop('skillOverrides',None)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      echo "$json" | __cc_save_settings
      echo "[OK]  Switched to 'default' profile: all skills visible"
      ;;
    minimal)
      json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['skillOverrides']={
    'document-skills:*': 'off',
    'example-skills:*': 'off',
    'financial-analysis:*': 'user-invocable-only',
    'pitch-agent:*': 'user-invocable-only',
    'claude-api:*': 'name-only'
}
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      echo "$json" | __cc_save_settings
      echo "[OK]  Switched to 'minimal' profile: hidden docs/examples, financial/pitch menu-only"
      ;;
    dev)
      json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['skillOverrides']={
    'document-skills:*': 'off',
    'example-skills:*': 'off',
    'financial-analysis:*': 'off',
    'pitch-agent:*': 'off',
    'claude-api:claude-api': 'user-invocable-only'
}
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      echo "$json" | __cc_save_settings
      echo "[OK]  Switched to 'dev' profile: dev skills only"
      ;;
    custom)
      echo "[NOTE]  Custom profile: edit ~/.claude/settings.json skillOverrides manually"
      ;;
    *)
      echo "Usage: cc-profile {default|minimal|dev|custom}"
      ;;
  esac
}

# === COMMAND MANAGEMENT ===
cc-commands() {
  local action="${1:-list}"
  local name="${2:-}"
  local desc="${3:-}"

  local commands_dir="$HOME/.claude/commands"

  case "$action" in
    list)
      echo "[LIST]  Custom Slash Commands:"
      if [[ -d "$commands_dir" ]]; then
        local files=("$commands_dir"/*.md)
        if [[ -f "${files[0]}" ]]; then
          for f in "$commands_dir"/*.md; do
            local d=""
            d="$(head -10 "$f" | grep "^description:" | sed 's/^description: *//;s/"//g')"
            echo "  /$(basename "$f" .md) — $d"
          done
        else
          echo "  (none)"
        fi
      else
        echo "  (commands dir not found)"
      fi
      ;;
    create)
      if [[ -z "$name" ]]; then
        echo "Usage: cc-commands create <name> <description>"
        return
      fi
      mkdir -p "$commands_dir"
      local filepath="$commands_dir/$name.md"
      if [[ -f "$filepath" ]]; then
        echo "[!]   /$name already exists"
        return
      fi
      cat > "$filepath" <<EOF
---
description: ${desc:-""}
---
EOF
      echo "[OK]  Created /$name -> $filepath"
      ;;
    remove)
      if [[ -z "$name" ]]; then
        echo "Usage: cc-commands remove <name>"
        return
      fi
      local filepath="$commands_dir/$name.md"
      if [[ -f "$filepath" ]]; then
        rm "$filepath"
        echo "[OK]  Deleted /$name"
      else
        echo "[!]   /$name not found"
      fi
      ;;
    *)
      echo "Usage: cc-commands {list|create|remove} [name] [description]"
      ;;
  esac
}

# === THEME MANAGEMENT (Oh My Posh) ===
cc-theme() {
  local name="${1:-}"

  local oh_my_posh
  if command -v oh-my-posh &>/dev/null; then
    oh_my_posh="oh-my-posh"
  elif [[ -x "/opt/homebrew/bin/oh-my-posh" ]]; then
    oh_my_posh="/opt/homebrew/bin/oh-my-posh"
  elif [[ -x "/usr/local/bin/oh-my-posh" ]]; then
    oh_my_posh="/usr/local/bin/oh-my-posh"
  else
    echo "[!]   Oh My Posh not installed."
    echo "  Install: brew install oh-my-posh"
    return
  fi

  local theme_dir
  theme_dir="$("$oh_my_posh" cache path 2>/dev/null)/themes"
  [[ ! -d "$theme_dir" ]] && theme_dir="$(dirname "$(dirname "$oh_my_posh")")/themes"
  [[ ! -d "$theme_dir" ]] && theme_dir="/opt/homebrew/opt/oh-my-posh/themes"
  [[ ! -d "$theme_dir" ]] && theme_dir="/usr/local/opt/oh-my-posh/themes"

  if [[ ! -d "$theme_dir" ]]; then
    echo "[!]   Oh My Posh themes not found."
    return
  fi

  if [[ -n "$name" ]]; then
    local theme_file="$theme_dir/$name.omp.json"
    if [[ ! -f "$theme_file" ]]; then
      echo "[!]   Theme '$name' not found."
      echo "  Themes available:"
      ls "$theme_dir"/*.omp.json 2>/dev/null | while IFS= read -r f; do
        basename "$f" .omp.json
      done
      return
    fi
    eval "$("$oh_my_posh" init zsh --config "$theme_file")"
    echo "[OK]  Switched to theme: $name"
    echo "  To make permanent, add to ~/.zshrc:"
    echo '    eval "$(oh-my-posh init zsh --config '"$theme_file"')"'
    return
  fi

  echo ""
  echo "=== Oh My Posh Themes ==="
  echo ""

  local popular=("powerlevel10k_rainbow" "powerlevel10k_classic" "montys" "catppuccin" "star" "tokyonight_storm" "gruvbox" "dracula")

  ls "$theme_dir"/*.omp.json 2>/dev/null | while IFS= read -r f; do
    local base
    base="$(basename "$f" .omp.json)"
    local marker="   "
    for p in "${popular[@]}"; do
      [[ "$base" == "$p" ]] && marker=" =>"
    done
    echo "  $marker $base"
  done

  echo ""
  echo "Usage:"
  echo "  cc-theme <name>    Switch to theme (live preview)"
  echo "  cc-theme           Show this list"
  echo "  cc-theme montys    Example: switch to montys"
  echo ""
  echo "To make permanent, add the init line to ~/.zshrc"
  echo "Popular themes marked with =>"
}

# === STATUS ===
cc-status() {
  local json
  json="$(__cc_read_settings)" || return 1

  local current
  current="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_MODEL','(unknown)')")"
  local model
  model="$(echo "$json" | __cc_json_get "d.get('model','(unknown)')")"
  local fallback
  fallback="$(echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); fb=d.get('fallbackModel',[]); print(','.join(fb) if fb else '(none)')")"
  local base_url="${ANTHROPIC_BASE_URL:-$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_BASE_URL','(not set)')")}"
  local available_count
  available_count="$(echo "$json" | __cc_json_get "len(d.get('availableModels',[]))")"

  echo ""
  echo "=== Claude Code Model Status ==="
  echo "  Current : $current"
  echo "  Model   : $model"
  echo "  Fallback: $fallback"
  echo "  Base URL: $base_url"
  echo "  Available: $available_count models"
  echo ""

  # Show task assignments if configured
  local has_tm
  has_tm="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print('yes' if isinstance(tm,dict) and tm else 'no')
")"
  if [[ "$has_tm" == "yes" ]]; then
    echo "Task assignments:"
    echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict):
    for t in ['code','quick','reason','image','default']:
        if t in tm:
            print(f'  {t:8} → {tm[t]}')
"
    echo ""
  fi

  echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
current='$current'
models=d.get('availableModels',[])

def get_cat(m):
    if m.startswith('gpt-') or m.startswith('o'): return 'GPT'
    if m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'): return 'Claude'
    if m.startswith('deepseek'): return 'DeepSeek'
    if m.startswith('qwen'): return 'Qwen'
    if m.startswith('grok'): return 'Grok'
    if m.startswith('kimi') or m.startswith('moonshot'): return 'Moonshot'
    if m.startswith('llama'): return 'Llama'
    if m.startswith('mistral') or m.startswith('mixtral'): return 'Mistral'
    if m.startswith('gemin'): return 'Gemini'
    if 'step' in m.lower(): return 'Stepfun'
    return 'Other'

groups = {}
for m in models:
    cat = get_cat(m)
    groups.setdefault(cat, []).append(m)

order = {'GPT':1,'Claude':2,'DeepSeek':3,'Grok':4,'Qwen':5,'Gemini':6,'Moonshot':7,'Llama':8,'Mistral':9,'Stepfun':10,'Other':99}
for gname in sorted(groups.keys(), key=lambda g: order.get(g,99)):
    if groups[gname]:
        print(f'{gname} ({len(groups[gname])})')
        for m in sorted(groups[gname]):
            marker=' <-- current' if m==current else ''
            print(f'  {m}{marker}')
        print('')
"
}

# === MENU DISPLAY ===
__cc_show_menu() {
  local current
  current="$(__cc_get_current_model 2>/dev/null)" || current="(unknown)"

  echo ""
  echo "=== Claude Code Model Switcher ==="
  echo ""
  echo "  cc <model>         Switch and launch (with health check)"
  echo "  cc                 Auto-discover CPA + assign tasks + menu"
  echo "  cc-run <task>      Launch with task model (code/quick/reason/image/default)"
  echo "  cc-config          View/override task-model assignments"
  echo "  cc-status          Full model inventory with task assignments"
  echo "  cc-sync            Sync models from CPA"
  echo "    cc-sync --list    Show full CPA model list"
  echo "    cc-sync --force   Auto-add new models"
  echo "    cc-sync --remove  Remove obsolete models"
  echo "    cc-sync --reassign Sync + reassign task models"
  echo ""
  echo "  cc-test            Test all models for health"
  echo "  cc-audit           Audit skill visibility"
  echo "  cc-hide <skill>    Hide skill or plugin"
  echo "  cc-show <skill>    Restore hidden skill"
  echo "  cc-profile <name>  Switch preset (default|minimal|dev)"
  echo "  cc-commands        List/manage custom commands"
  echo ""
  echo "  cc-pro             Code task model"
  echo "  cc-fast            Quick task model"
  echo "  cc-default         Default task model"
  echo ""
  echo "Current: $current"
  echo ""

  local json
  json="$(__cc_read_settings 2>/dev/null)" || return

  # Show task assignments if available
  local has_tm
  has_tm="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
print('yes' if isinstance(tm,dict) and tm else 'no')
" 2>/dev/null)"
  if [[ "$has_tm" == "yes" ]]; then
    echo "Task assignments (cc-config to change):"
    echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tm=d.get('taskModels',{})
if isinstance(tm,dict):
    for t in ['code','quick','reason','image','default']:
        if t in tm:
            print(f'  {t:8} → {tm[t]}')
"
    echo ""
  fi

  echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
" 2>/dev/null | __cc_categorize_models
}
