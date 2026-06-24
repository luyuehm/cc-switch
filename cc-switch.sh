# cc-switch.sh — Claude Code Model Switcher for macOS (zsh/bash)
# Source: . ./cc-switch.sh   or add to ~/.zshrc
# https://github.com/luyuehm/cc-switch

CC_SETTINGS_PATH="$HOME/.claude/settings.json"
CC_ENV_PATH="$HOME/.claude/cc-switch.env"

__cc_load_env() {
  [[ -f "$CC_ENV_PATH" ]] || return
  # Skip auto-export if CC_SWITCH_SKIP_ENV is set (prevents "Both claude.ai and API_KEY" conflict)
  # See README.md#claudeai-conflict for details.
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

# === MAIN COMMAND ===
cc() {
  local model="${1:-}"

  if [[ -z "$model" ]]; then
    __cc_show_menu
    return
  fi

  local json
  json="$(__cc_read_settings)" || return 1

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
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth_key="$ANTHROPIC_API_KEY"
  else
    auth_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
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

# === SHORTCUTS ===
cc-pro() {
  echo "Switching to claude-opus-4-7..."
  cc claude-opus-4-7
}

cc-fast() {
  echo "Switching to deepseek-v4-flash..."
  cc deepseek-v4-flash
}

cc-default() {
  echo "Restoring gpt-5.5..."
  cc gpt-5.5
}

# === CPA SYNC ===
cc-sync() {
  local list_mode=0 force=0 remove=0

  for arg in "$@"; do
    case "$arg" in
      -List|--list) list_mode=1 ;;
      -Force|--force) force=1 ;;
      -Remove|--remove) remove=1 ;;
    esac
  done

  CC_SWITCH_SKIP_ENV=0 __cc_load_env
  local cpa_url="${CPA_MODELS_URL:-}"
  local api_key="${ANTHROPIC_API_KEY:-}"

  if [[ -z "$cpa_url" ]]; then
    local json
    json="$(__cc_read_settings 2>/dev/null)" || true
    if [[ -n "$json" ]]; then
      local base_url
      base_url="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_BASE_URL','')")"
      [[ -n "$base_url" ]] && cpa_url="${base_url%/}/v1/models"
    fi
  fi

  if [[ -z "$api_key" ]]; then
    local json
    json="$(__cc_read_settings 2>/dev/null)" || true
    if [[ -n "$json" ]]; then
      api_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
    fi
  fi

  if [[ -z "$cpa_url" || -z "$api_key" ]]; then
    echo "Error: CPA_MODELS_URL or API key not configured." >&2
    echo "  Set CPA_MODELS_URL and ANTHROPIC_API_KEY in ~/.claude/cc-switch.env" >&2
    return 1
  fi

  echo "Fetching models from CPA..."
  echo "  $cpa_url"

  local response
  response="$(curl -s --max-time 15 "$cpa_url" \
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

  echo "$cpa_models" | python3 -c "
import sys
models=[l.strip() for l in sys.stdin if l.strip()]
cats={}
for m in models:
    if m.startswith('gpt-') or m.startswith('o'):
        cat='GPT'
    elif m.startswith('claude-') or m.startswith('sonnet') or m.startswith('haiku'):
        cat='Claude'
    elif m.startswith('deepseek'):
        cat='DeepSeek'
    elif m.startswith('qwen'):
        cat='Qwen'
    elif m.startswith('grok'):
        cat='Grok'
    elif m.startswith('llama'):
        cat='Llama'
    elif m.startswith('mistral') or m.startswith('mixtral'):
        cat='Mistral'
    elif m.startswith('gemin'):
        cat='Gemini'
    elif m.startswith('kimi') or m.startswith('moonshot'):
        cat='Moonshot'
    elif 'step' in m:
        cat='Stepfun'
    else:
        cat='Other'
    cats.setdefault(cat, []).append(m)
for cat in sorted(cats.keys(), key=lambda c: {'GPT':1,'Claude':2,'DeepSeek':3,'Grok':4,'Qwen':5,'Gemini':6,'Moonshot':7,'Llama':8,'Mistral':9,'Stepfun':10}.get(c,99)):
    print(f'  [{cat}]')
    for m in cats[cat]:
        print(f'    {m}')
"

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

  echo ""
  echo "Tip: cc-sync --list      -- show full model list only"
  echo "Tip: cc-sync --force     -- auto-add new models"
  echo "Tip: cc-sync --remove    -- remove obsolete models"
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

  echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
current='$current'
models=d.get('availableModels',[])
groups={'GPT':[],'Claude':[],'DeepSeek':[],'Qwen':[],'Grok':[],'Moonshot':[],'Stepfun':[],'Other':[]}
for m in models:
    if m.startswith('gpt-') or m.startswith('o'): groups['GPT'].append(m)
    elif 'claude' in m.lower(): groups['Claude'].append(m)
    elif 'deepseek' in m.lower(): groups['DeepSeek'].append(m)
    elif 'qwen' in m.lower(): groups['Qwen'].append(m)
    elif m.startswith('grok'): groups['Grok'].append(m)
    elif 'moonshot' in m.lower(): groups['Moonshot'].append(m)
    elif 'step' in m.lower(): groups['Stepfun'].append(m)
    else: groups['Other'].append(m)
for gname in sorted(groups.keys(), key=lambda g: len(groups[g]), reverse=True):
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
  echo "  cc <model>         Switch and launch"
  echo "  cc                 This menu"
  echo "  cc-status          Full model inventory"
  echo "  cc-sync            Sync models from CPA"
  echo "    cc-sync --list    Show full CPA model list"
  echo "    cc-sync --force   Auto-add new models"
  echo "    cc-sync --remove  Remove obsolete models"
  echo ""
  echo "  cc-audit           Audit skill visibility"
  echo "  cc-hide <skill>    Hide skill or plugin"
  echo "  cc-show <skill>    Restore hidden skill"
  echo "  cc-profile <name>  Switch preset (default|minimal|dev)"
  echo "  cc-commands        List/manage custom commands"
  echo ""
  echo "  cc-pro             claude-opus-4-7"
  echo "  cc-fast            deepseek-v4-flash"
  echo "  cc-default         gpt-5.5"
  echo ""
  echo "Current: $current"
  echo ""

  local json
  json="$(__cc_read_settings 2>/dev/null)" || return
  echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
models=d.get('availableModels',[]) or []
cats={}
for m in models:
    if m.startswith('gpt-') or m.startswith('o'): cat='GPT'
    elif 'claude' in m.lower(): cat='Claude'
    elif 'deepseek' in m.lower(): cat='DeepSeek'
    elif 'qwen' in m.lower(): cat='Qwen'
    elif m.startswith('grok'): cat='Grok'
    elif 'kimi' in m.lower() or 'moonshot' in m.lower(): cat='Moonshot'
    elif 'llama' in m.lower(): cat='Llama'
    elif 'mistral' in m.lower() or 'mixtral' in m.lower(): cat='Mistral'
    elif 'gemin' in m.lower(): cat='Gemini'
    elif 'step' in m.lower(): cat='Stepfun'
    else: cat='Other'
    cats.setdefault(cat, []).append(m)
order={'GPT':1,'Claude':2,'DeepSeek':3,'Grok':4,'Qwen':5,'Gemini':6,'Moonshot':7,'Llama':8,'Mistral':9,'Stepfun':10,'Other':99}
for cat in sorted(cats.keys(), key=lambda c: order.get(c,99)):
    print(f\"{cat}: \"+'  '.join(cats[cat]))
" 2>/dev/null
}
