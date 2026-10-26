# cc-switch.sh — Claude Code Model Switcher for macOS (zsh/bash)
# Source: . ./cc-switch.sh   or add to ~/.zshrc
# https://github.com/luyuehm/cc-switch
# v2.4.0 — Health check, CPA auto-discovery, cc-run, cc-config, cc-test

CC_SETTINGS_PATH="${CC_SETTINGS_PATH:-$HOME/.claude/settings.json}"
CC_ENV_PATH="${CC_ENV_PATH:-$HOME/.claude/cc-switch.env}"

# ─── Model identity (RIC-1845) ───
# The provider's raw ID is the source of truth. `a-`-prefixed IDs (e.g.
# a-deepseek-flash) are FIRST-CLASS models, not aliases of the bare name:
# they are fetched, stored, selected, health-checked and removed under their
# raw ID. A canonical/alias mapping is applied ONLY when the raw ID has an
# explicit entry in CC_ALIAS_FILE — an unconfirmed alias is never normalized,
# and no model is ever dropped because of its prefix.
CC_ALIAS_FILE="${CC_ALIAS_FILE:-$HOME/.claude/cc-model-aliases.json}"
# Health evidence log (JSONL). Set CC_HEALTH_LOG="" to disable.
CC_HEALTH_LOG="${CC_HEALTH_LOG:-$HOME/.claude/cc-health.log}"

# Parse a CPA /v1/models response (JSON on stdin) into raw IDs, one per line.
# No prefix filtering, no alias rewrite, no collapsing of distinct IDs.
__cc_parse_cpa_response() {
  python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
if isinstance(d, dict) and isinstance(d.get('data'), list):
    models=[m.get('id') for m in d['data'] if isinstance(m, dict) and m.get('id')]
elif isinstance(d, list):
    models=[m.get('id') if isinstance(m, dict) else None for m in d]
else:
    models=[]
seen=set()
for m in sorted({str(x) for x in models if x}):
    if m in seen:
        continue
    seen.add(m)
    print(m)
"
}

# Map raw IDs (one per line on stdin) to '<raw_id>\t<canonical_id>' pairs.
# canonical_id == raw_id unless a confirmed alias exists in CC_ALIAS_FILE.
__cc_model_identity() {
  CC_ALIAS_FILE="$CC_ALIAS_FILE" python3 -c "
import json,os,sys
alias={}
p=os.environ.get('CC_ALIAS_FILE','')
if p and os.path.isfile(p):
    try:
        raw=json.load(open(p))
        if isinstance(raw,dict):
            alias={str(k):str(v) for k,v in raw.items() if isinstance(v,str) and v}
    except Exception:
        alias={}
for line in sys.stdin:
    m=line.strip()
    if not m:
        continue
    print('%s\t%s' % (m, alias.get(m, m)))
"
}

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

# Read a single KEY from an env file WITHOUT exporting it.
# Usage: __cc_env_file_get KEY [FILE]   (FILE defaults to $CC_ENV_PATH)
# Why: ~/.zshrc exports CC_SWITCH_SKIP_ENV=1 so __cc_load_env is a no-op at
# shell startup. Commands that need credentials must still see them, and they
# must not leak into the interactive shell's environment.
__cc_env_file_get() {
  local key="$1" file="${2:-$CC_ENV_PATH}"
  [[ -n "$key" && -f "$file" ]] || return 0
  grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- \
    | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

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
    local dir; dir="$(dirname "$CC_SETTINGS_PATH")"
    [[ -d "$dir" ]] || mkdir -p "$dir" || return 1
    printf '{"availableModels":[],"env":{}}\n' > "$CC_SETTINGS_PATH" || return 1
  # RIC-1851: never overwrite an existing settings file just because it failed to
  # parse — that would silently delete every user model. Report it instead.
  elif ! CC_SETTINGS_PATH="$CC_SETTINGS_PATH" python3 -c "
import json,os,sys
try:
    json.load(open(os.environ['CC_SETTINGS_PATH']))
except Exception as e:
    sys.stderr.write('cc-switch: %s is not valid JSON, refusing to overwrite: %s\n'
                     % (os.environ['CC_SETTINGS_PATH'], e))
    sys.exit(1)
" 2>/dev/null; then
    echo "Error: '$CC_SETTINGS_PATH' is not valid JSON — refusing to overwrite it." >&2
    echo "       Restore a backup or fix the file, then retry." >&2
    return 1
  fi
  cat "$CC_SETTINGS_PATH"
}

__cc_save_settings() {
  # RIC-1845: persist model IDs exactly as given. No 'a-' stripping, no silent
  # drops, no alias rewrite — a-deepseek-flash and deepseek-flash are distinct
  # entries. Existing values that are already bare are left untouched.
  #
  # RIC-1851: CC_SETTINGS_PATH is a plain shell variable (line 6) that is never
  # exported, so the child Python could not see it in os.environ and died with
  # KeyError:'CC_SETTINGS_PATH' — after which callers printed success anyway.
  # Pass it explicitly, and treat it as mandatory: an empty path is a hard error,
  # never a silent skip.
  local __cc_save_rc=0
  CC_SETTINGS_PATH="$CC_SETTINGS_PATH" python3 -c "
import json,sys,os

path = os.environ.get('CC_SETTINGS_PATH') or ''
if not path:
    sys.stderr.write('cc-switch: CC_SETTINGS_PATH is not set — cannot save settings\n')
    sys.exit(2)

try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write('cc-switch: refusing to save invalid JSON: %s\n' % e)
    sys.exit(1)

def keep(m):
    # Only reject empty/non-string entries; every concrete model ID is valid.
    if not isinstance(m, str):
        return None
    m = m.strip()
    return m or None

# env: model-valued keys
for k, v in list(d.get('env', {}).items()):
    if 'MODEL' in k and isinstance(v, str):
        r = keep(v)
        if r is not None:
            d['env'][k] = r
for k in ('model',):
    if isinstance(d.get(k), str):
        r = keep(d[k])
        if r is not None:
            d[k] = r
# fallbackModel: string or list — dedupe exact duplicates only
fb = d.get('fallbackModel')
if isinstance(fb, str):
    r = keep(fb)
    if r is not None:
        d['fallbackModel'] = r
elif isinstance(fb, list):
    seen = set(); out = []
    for m in fb:
        r = keep(m)
        if r is None or r in seen:
            continue
        seen.add(r); out.append(r)
    d['fallbackModel'] = out
# availableModels: keep every distinct ID, sorted for stable diffs
am = d.get('availableModels')
if isinstance(am, list):
    seen = set(); uniq = []
    for m in am:
        r = keep(m)
        if r is None or r in seen:
            continue
        seen.add(r); uniq.append(r)
    d['availableModels'] = sorted(uniq)
# taskModels: values are raw model IDs; leave them alone
# Atomic write: a crash or full disk must not truncate the live settings file.
tmp = path + '.tmp-cc-%d' % os.getpid()
try:
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write('\n')
    os.replace(tmp, path)
except Exception as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.stderr.write('cc-switch: failed to write %s: %s\n' % (path, e))
    sys.exit(3)
" || __cc_save_rc=$?

  if [[ "$__cc_save_rc" -ne 0 ]]; then
    echo "Error: failed to save settings to $CC_SETTINGS_PATH (exit $__cc_save_rc)" >&2
    return "$__cc_save_rc"
  fi
  return 0
}

__cc_get_current_model() {
  local json
  json="$(__cc_read_settings)" || return 1
  echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('env',{}).get('ANTHROPIC_MODEL','(unknown)'))"
}

# ─── CPA Endpoint Resolution ───
# Priority: shell ANTHROPIC_BASE_URL > $CPA_MODELS_URL > cc-switch.env > ~/.openclaw/.env > settings.json
# Auth: shell ANTHROPIC_AUTH_TOKEN > shell ANTHROPIC_API_KEY > $CPA_API_KEY > cc-switch.env > ~/.openclaw/.env > settings.json
# NOTE: ~/.zshrc exports CC_SWITCH_SKIP_ENV=1, so __cc_load_env never runs at
# shell startup and $CC_ENV_PATH is *not* in the environment. Every source below
# is therefore also read straight from disk via __cc_env_file_get.
# NOTE: `json` is declared exactly once per function — zsh 5.9 prints
# "json=..." to stdout when a bare `local` re-declares an existing local.
__cc_resolve_endpoint() {
  local shell_url="${ANTHROPIC_BASE_URL:-}"
  local shell_token="${ANTHROPIC_AUTH_TOKEN:-}"
  local shell_key="${ANTHROPIC_API_KEY:-}"

  local cpa_url=""
  local api_key=""
  local json=""
  local base_url=""
  local env_url=""

  # URL resolution
  if [[ -n "$shell_url" ]]; then
    cpa_url="${shell_url%/}/v1/models"
  elif [[ -n "${CPA_MODELS_URL:-}" ]]; then
    cpa_url="$CPA_MODELS_URL"
  else
    # Fallback 1: read $CC_ENV_PATH from disk (its vars are NOT in the shell
    # because CC_SWITCH_SKIP_ENV=1 suppresses the startup export)
    cpa_url="$(__cc_env_file_get CPA_MODELS_URL)"
    if [[ -z "$cpa_url" ]]; then
      env_url="$(__cc_env_file_get CLAUDE_CODE_BASE_URL)"
      [[ -z "$env_url" ]] && env_url="$(__cc_env_file_get ANTHROPIC_BASE_URL)"
      [[ -n "$env_url" ]] && cpa_url="${env_url%/}/v1/models"
    fi
    # Fallback 2: ~/.openclaw/.env (unified config)
    if [[ -z "$cpa_url" ]]; then
      env_url="$(__cc_env_file_get CLAUDE_CODE_BASE_URL "$HOME/.openclaw/.env")"
      [[ -n "$env_url" ]] && cpa_url="${env_url%/}/v1/models"
    fi
  fi

  # If still empty, try settings.json
  if [[ -z "$cpa_url" ]]; then
    json="$(__cc_read_settings 2>/dev/null)" || true
    if [[ -n "$json" ]]; then
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
    # Fallback 1: same file, on disk
    api_key="$(__cc_env_file_get ANTHROPIC_AUTH_TOKEN)"
    [[ -z "$api_key" ]] && api_key="$(__cc_env_file_get ANTHROPIC_API_KEY)"
    [[ -z "$api_key" ]] && api_key="$(__cc_env_file_get CPA_API_KEY)"
    # Fallback 2: ~/.openclaw/.env
    [[ -z "$api_key" ]] && api_key="$(__cc_env_file_get CPA_API_KEY "$HOME/.openclaw/.env")"
  fi

  # If still empty, try settings.json
  if [[ -z "$api_key" ]]; then
    [[ -z "$json" ]] && { json="$(__cc_read_settings 2>/dev/null)" || true; }
    if [[ -n "$json" ]]; then
      api_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_AUTH_TOKEN','')")"
      [[ -z "$api_key" ]] && api_key="$(echo "$json" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
    fi
  fi

  echo "${cpa_url}|${api_key}"
}

# Normalize a CPA address ("http://host", "http://host/v1", "http://host/v1/models")
# into "base_url|models_url". The base is what Claude Code needs, since it appends
# /v1/messages itself.
__cc_normalize_endpoint() {
  local url="${1%/}"
  local base=""
  case "$url" in
    */v1/models) base="${url%/v1/models}" ;;
    */v1) base="${url%/v1}" ;;
    *) base="$url" ;;
  esac
  base="${base%/}"
  [[ -z "$base" ]] && return 1
  printf '%s|%s/v1/models\n' "$base" "$base"
}

# Emit "label|base_url|models_url|api_key" for every address in $CPA_FALLBACK_URLS.
# Entries are separated by ';' or ','; an entry may pin its own key as "url|key".
# A fallback without its own key reuses $CPA_FALLBACK_API_KEY, then the primary key.
__cc_resolve_fallbacks() {
  local spec="${CPA_FALLBACK_URLS:-}"
  [[ -z "$spec" ]] && spec="$(__cc_env_file_get CPA_FALLBACK_URLS)"
  [[ -z "$spec" ]] && return 0

  local default_key="${CPA_FALLBACK_API_KEY:-}"
  [[ -z "$default_key" ]] && default_key="$(__cc_env_file_get CPA_FALLBACK_API_KEY)"
  if [[ -z "$default_key" ]]; then
    local primary_raw
    primary_raw="$(__cc_resolve_endpoint)"
    default_key="${primary_raw##*|}"
  fi

  local index=0 entry url key norm base
  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$entry" ]] && continue
    index=$((index + 1))
    url="$entry"
    key="$default_key"
    if [[ "$entry" == *"|"* ]]; then
      url="${entry%%|*}"
      key="${entry#*|}"
    fi
    norm="$(__cc_normalize_endpoint "$url")" || continue
    base="${norm%%|*}"
    printf 'fallback-%d|%s|%s|%s\n' "$index" "$base" "${norm#*|}" "$key"
  done <<< "$(printf '%s' "$spec" | tr ';,' '\n')"
}

# ─── Health Check ───
# Ping a model via POST /v1/messages using its RAW ID to verify it's responsive.
# Every probe — a- prefixed or not — takes the same path; the prefix is never a
# reason to skip. Evidence (raw_id, http_status, error_class) is appended to
# CC_HEALTH_LOG as JSONL when a status is observed.
# Uses in-memory cache with 60s TTL.
# Returns 0 if healthy, 1 if unhealthy.
__cc_health_log() {
  local model_id="$1" http_status="$2" error_class="$3" detail="$4"
  [[ -z "${CC_HEALTH_LOG:-}" ]] && return 0
  CC_HEALTH_LOG="$CC_HEALTH_LOG" python3 -c "
import json,os,time,sys
rec={'ts':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
     'raw_id':sys.argv[1],'http_status':sys.argv[2],
     'error_class':sys.argv[3],'detail':sys.argv[4][:200]}
try:
    with open(os.environ['CC_HEALTH_LOG'],'a') as f:
        f.write(json.dumps(rec,ensure_ascii=False)+'\n')
except Exception:
    pass
" "$model_id" "$http_status" "$error_class" "$detail" 2>/dev/null || true
}

__cc_test_model_health() {
  local model="$1"
  local timeout_sec="${2:-10}"
  local now
  now="$(date +%s)"

  # Last observed probe evidence (read by cc-sync --health).
  CC_LAST_HEALTH_STATUS=""
  CC_LAST_HEALTH_CLASS=""
  CC_LAST_HEALTH_DETAIL=""

  # Check cache (defensive: skip if format is corrupt — no arithmetic needed)
  local cached="${__cc_health_cache[$model]:-}"
  if [[ -n "$cached" && "$cached" == *:* ]]; then
    local cache_ts="${cached%%:*}"
    local cache_val="${cached##*:}"
    # Only use cache if timestamp is numeric and value is valid
    if [[ "$cache_ts" =~ ^[0-9]+$ ]] && [[ "$cache_val" =~ ^(healthy|unhealthy)$ ]]; then
      if [[ $(( now - cache_ts )) -lt $CC_HEALTH_CACHE_TTL ]]; then
        CC_LAST_HEALTH_STATUS="cache"
        CC_LAST_HEALTH_CLASS="$cache_val"
        [[ "$cache_val" == "healthy" ]] && return 0 || return 1
      fi
    fi
  fi

  # Resolve endpoint
  local ep_raw
  ep_raw="$(__cc_resolve_endpoint)"
  local api_key="${ep_raw##*|}"
  local cpa_url="${ep_raw%|*}"
  local base_url
  # cc-test exports the endpoint that actually answers (read-only failover) so that
  # health results describe the endpoint Claude Code would talk to right now.
  base_url="${CC_ACTIVE_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
  [[ -n "${CC_ACTIVE_API_KEY:-}" ]] && api_key="$CC_ACTIVE_API_KEY"
  [[ -z "$base_url" ]] && base_url="${cpa_url%/v1/models}"
  base_url="${base_url%/}"

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    __cc_health_cache[$model]="$now:unhealthy"
    __cc_health_log "$model" "000" "no_endpoint" "base_url or api_key missing"
    CC_LAST_HEALTH_STATUS="000"
    CC_LAST_HEALTH_CLASS="no_endpoint"
    return 1
  fi

  local messages_url="${base_url%/}/v1/messages"

  # Use realistic payload to exercise the pipeline
  local body
  body=$(cat <<EOF
{"model":"$model","system":"You are a helpful assistant.","messages":[{"role":"user","content":"ping"}],"max_tokens":5}
EOF
)

  local response http_code
  http_code="$(curl -s --connect-timeout 5 --max-time "$timeout_sec" \
    -o /tmp/.cc_health_body.$$ -w '%{http_code}' \
    -X POST "$messages_url" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "$body" 2>/dev/null)" || http_code="000"
  response="$(cat /tmp/.cc_health_body.$$ 2>/dev/null)"
  rm -f /tmp/.cc_health_body.$$

  if [[ "$http_code" == "000" ]]; then
    __cc_health_cache[$model]="$now:unhealthy"
    __cc_health_log "$model" "000" "transport" "curl failed or timed out"
    CC_LAST_HEALTH_STATUS="000"
    CC_LAST_HEALTH_CLASS="transport"
    return 1
  fi

  # Classify by HTTP status first, then by body.
  local klass=""
  case "$http_code" in
    2[0-9][0-9]) ;;
    401|403) klass="auth" ;;
    404) klass="not_found" ;;
    429) klass="rate_limit" ;;
    5[0-9][0-9]) klass="upstream" ;;
    *) klass="http_$http_code" ;;
  esac

  # Check for hidden error body (some proxies return 200 with error JSON)
  if [[ -z "$klass" ]] && echo "$response" | grep -qiE '"error"|"overloaded"|"unavailable"'; then
    klass="error_body"
  fi

  if [[ -n "$klass" ]]; then
    __cc_health_cache[$model]="$now:unhealthy"
    __cc_health_log "$model" "$http_code" "$klass" "$response"
    CC_LAST_HEALTH_STATUS="$http_code"
    CC_LAST_HEALTH_CLASS="$klass"
    CC_LAST_HEALTH_DETAIL="$response"
    return 1
  fi

  __cc_health_cache[$model]="$now:healthy"
  __cc_health_log "$model" "$http_code" "" ""
  CC_LAST_HEALTH_STATUS="$http_code"
  CC_LAST_HEALTH_CLASS="ok"
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
# Emits provider raw IDs verbatim (RIC-1845). 'a-' IDs are kept as first-class
# entries; nothing is mapped to a bare name and nothing is filtered by prefix.
#
# Tries the primary endpoint first, then every address in $CPA_FALLBACK_URLS.
# Failover happens on transport failure, timeout and 5xx; a 4xx is a real answer
# (bad key / wrong path / quota) and is surfaced instead of being masked.
# The endpoint actually used is left in CC_LAST_CPA_ENDPOINT / _LABEL / _API_KEY.
CC_LAST_CPA_ENDPOINT=""
CC_LAST_CPA_ENDPOINT_LABEL=""
CC_LAST_CPA_API_KEY=""

__cc_fetch_cpa_models() {
  local ep_raw primary_key primary_url
  CC_LAST_CPA_ENDPOINT=""
  CC_LAST_CPA_ENDPOINT_LABEL=""
  CC_LAST_CPA_API_KEY=""
  ep_raw="$(__cc_resolve_endpoint)"
  primary_key="${ep_raw##*|}"
  primary_url="${ep_raw%|*}"

  local candidates="" norm
  if [[ -n "$primary_url" ]]; then
    norm="$(__cc_normalize_endpoint "$primary_url" 2>/dev/null)" || norm=""
    [[ -n "$norm" ]] && candidates="primary|${norm%%|*}|${norm#*|}|$primary_key"$'\n'
  fi
  candidates+="$(__cc_resolve_fallbacks)"

  local body_file
  body_file="$(mktemp 2>/dev/null || echo "/tmp/.cc_models.$$")"
  local label base models key code last_error="" rc=1

  while IFS='|' read -r label base models key; do
    [[ -z "$models" ]] && continue
    if [[ -z "$key" ]]; then
      last_error="$label $models: no API key"
      continue
    fi

    code="$(curl -s -o "$body_file" -w '%{http_code}' --connect-timeout 5 --max-time 15 \
      "$models" -H "Authorization: Bearer $key" -H "Content-Type: application/json" 2>/dev/null)" || code="000"

    case "$code" in
      000|5??)
        # No answer, or the relay itself is broken → the next endpoint may be fine.
        last_error="${last_error:+$last_error | }$label $models: HTTP $code"
        continue
        ;;
    esac

    if [[ "$code" != 2?? ]]; then
      # Real answer from the server: report it rather than hiding it behind a fallback.
      echo "$label $models: HTTP $code" >&2
      last_error="${last_error:+$last_error | }$label $models: HTTP $code"
      rc=1
      break
    fi

    CC_LAST_CPA_ENDPOINT="$base"
    CC_LAST_CPA_ENDPOINT_LABEL="$label"
    CC_LAST_CPA_API_KEY="$key"
    __cc_parse_cpa_response < "$body_file"
    rc=$?
    break
  done <<< "$candidates"

  rm -f "$body_file" 2>/dev/null
  if [[ -z "$CC_LAST_CPA_ENDPOINT" ]]; then
    [[ -n "$last_error" ]] && echo "No CPA endpoint answered: $last_error" >&2
    return 1
  fi
  return $rc
}

# ─── Model Categorization (Python helper, used by __cc_auto_assign and menu) ───
__cc_categorize_models_py() {
  python3 -c "
import sys
models = [l.strip() for l in sys.stdin if l.strip()]

def kind(m):
    # Categorization only: an 'a-' prefix is a serving-route marker, not a
    # different family. The raw ID itself is never rewritten.
    return m[2:] if m.startswith('a-') and len(m) > 2 else m

def get_cat(m):
    k = kind(m)
    if k.startswith('gpt-') or k.startswith('o'): return 'GPT'
    if k.startswith('claude-') or k.startswith('sonnet') or k.startswith('haiku'): return 'Claude'
    if k.startswith('deepseek'): return 'DeepSeek'
    if k.startswith('qwen'): return 'Qwen'
    if k.startswith('grok'): return 'Grok'
    if k.startswith('kimi') or k.startswith('moonshot'): return 'Moonshot'
    if k.startswith('llama'): return 'Llama'
    if k.startswith('mistral') or k.startswith('mixtral'): return 'Mistral'
    if k.startswith('gemin'): return 'Gemini'
    if 'step' in k.lower(): return 'Stepfun'
    return 'Other'

groups = {}
for m in models:
    cat = get_cat(m)
    groups.setdefault(cat, []).append(m)

def sort_key(m):
    # Bare IDs first, then 'a-' routes; preserves pre-RIC-1845 probe order.
    return (m.startswith('a-'), m)

for cat in sorted(groups):
    for m in sorted(groups[cat], key=sort_key):
        print(f'{cat}|{m}')
"
}

# ─── CPA Auto Discovery & Task Assignment ───
# Two-phase health verification: sequential probing + final re-ping
# Shows real-time progress: [1/5] code · model → healthy
__cc_auto_assign() {
  local start_time
  start_time="$(date +%s)"
  # Declared once: a bare `local json` later in this function would make zsh
  # print "json=..." to stdout and corrupt the assignment output.
  local json=""

  # Step 0: Fetch model list (with progress)
  echo -n "  Fetching CPA models..." >&2
  local cpa_models
  cpa_models="$(__cc_fetch_cpa_models 2>/dev/null)" || true

  if [[ -z "$cpa_models" ]]; then
    json="$(__cc_read_settings)" || return 1
    cpa_models="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
")"
    echo " (local, $(( $(echo "$cpa_models" | wc -l | tr -d ' ') )) models)" >&2
  else
    echo " ($(( $(echo "$cpa_models" | wc -l | tr -d ' ') )) models)" >&2
  fi

  [[ -z "$cpa_models" ]] && { echo "[!] No models available." >&2; return 1; }

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

  # Build category arrays
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

  local all_fallback=("${all_models[@]:0:20}")

  [[ ${#claude_paid[@]} -eq 0 ]] && claude_paid=("${claude_models[@]}")
  [[ ${#gpt_paid[@]} -eq 0 ]]    && gpt_paid=("${gpt_models[@]}")
  [[ ${#ds_paid[@]} -eq 0 ]]     && ds_paid=("${ds_models[@]}")
  [[ ${#qwen_paid[@]} -eq 0 ]]   && qwen_paid=("${qwen_models[@]}")

  local -A assign
  local selected

  # ── Helper: probe candidates and return first healthy, with progress ──
  __cc_probe_group() {
    local label="$1" candidates=("${@:2}")
    echo -n "  [$label]" >&2
    for candidate in "${candidates[@]}"; do
      [[ -z "$candidate" ]] && continue
      local cached="${__cc_health_cache[$candidate]:-}"
      if [[ -n "$cached" ]]; then
        local cache_val="${cached##*:}"
        if [[ "$cache_val" == "healthy" ]]; then
          echo " $candidate (cached)" >&2
          echo "$candidate"
          return 0
        fi
        continue
      fi
      echo -n " $candidate?" >&2
      if __cc_test_model_health "$candidate" 5; then
        echo " ✓" >&2
        echo "$candidate"
        return 0
      fi
      echo -n "✗" >&2
    done
    echo " (none)" >&2
    return 1
  }

  # Phase 1: Sequential per-group probing with real-time model names
  # code: Claude (non-haiku) → Claude → GPT → Qwen → anything
  local code_candidates=()
  for m in "${claude_paid[@]}"; do [[ "$m" != *haiku* ]] && code_candidates+=("$m"); done
  code_candidates+=("${claude_paid[@]}")
  code_candidates+=("${gpt_paid[@]}")
  code_candidates+=("${qwen_paid[@]}")
  code_candidates+=("${all_fallback[@]}")
  selected="$(__cc_probe_group "1/5 code  " "${code_candidates[@]}")" && assign[code]="$selected"

  # reason: GPT sol/reasoning → GPT → Qwen Plus/Max → Claude thinking → Claude → anything
  local reason_candidates=()
  for m in "${gpt_paid[@]}"; do echo "$m" | grep -qE "sol|reason|preview|thinking" && reason_candidates+=("$m"); done
  reason_candidates+=("${gpt_paid[@]}")
  for m in "${qwen_paid[@]}"; do echo "$m" | grep -qE "plus|max|preview" && reason_candidates+=("$m"); done
  reason_candidates+=("${qwen_paid[@]}")
  for m in "${claude_paid[@]}"; do echo "$m" | grep -q "thinking" && reason_candidates+=("$m"); done
  reason_candidates+=("${claude_paid[@]}")
  reason_candidates+=("${all_fallback[@]}")
  selected="$(__cc_probe_group "2/5 reason" "${reason_candidates[@]}")" && assign[reason]="$selected"

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
  selected="$(__cc_probe_group "3/5 quick " "${quick_candidates[@]}")" && assign[quick]="$selected"

  # image: image-specific → GPT → Grok image → anything
  local image_candidates=()
  image_candidates+=("${image_models[@]}")
  image_candidates+=("${gpt_paid[@]}")
  for m in "${grok_models[@]}"; do echo "$m" | grep -q "image" && image_candidates+=("$m"); done
  image_candidates+=("${all_fallback[@]}")
  selected="$(__cc_probe_group "4/5 image " "${image_candidates[@]}")" && assign[image]="$selected"

  # default: GPT → DeepSeek → Claude → Qwen → anything
  local default_candidates=()
  default_candidates+=("${gpt_paid[@]}")
  default_candidates+=("${ds_paid[@]}")
  default_candidates+=("${claude_paid[@]}")
  default_candidates+=("${qwen_paid[@]}")
  default_candidates+=("${all_fallback[@]}")
  selected="$(__cc_probe_group "5/5 deflt " "${default_candidates[@]}")" && assign[default]="$selected"

  # Phase 2: Final verification — re-ping (10s timeout, only 5 calls)
  echo -n "  Verifying:" >&2
  local task
  for task in code reason quick image default; do
    local model="${assign[$task]:-}"
    [[ -z "$model" ]] && continue
    unset "__cc_health_cache[$model]"
    if __cc_test_model_health "$model" 10; then
      echo -n " $model ✓" >&2
    else
      echo "" >&2
      echo "  [FALLBACK]  $model unhealthy for '$task', searching..." >&2
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
        echo -n " $m?" >&2
        if __cc_test_model_health "$m" 10; then
          new_selected="$m"
          echo -n " ✓" >&2
          break
        fi
        echo -n "✗" >&2
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
  echo "" >&2

  # Phase 3: Hard guard
  if [[ ${#assign[@]} -eq 0 ]]; then
    echo "[!] No healthy models found at all. Settings NOT saved." >&2
    return 1
  fi

  local elapsed=$(( $(date +%s) - start_time ))
  local total_str=""
  (( ${#assign[@]} < 5 )) && total_str=" (${#assign[@]}/5 tasks assigned)"
  echo "  All ${#assign[@]} assigned models verified healthy${total_str} (${elapsed}s)" >&2

  # Save to settings.json
  json="$(__cc_read_settings)" || return 1

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

  json="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
cpa_list='''$cpa_models'''
models=[m.strip() for m in cpa_list.split('\n') if m.strip()]
d['availableModels']=sorted(set(models))
d['taskModels']=$tm_json
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
  echo "$json" | __cc_save_settings || return 1

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

def kind(m):
    return m[2:] if m.startswith('a-') and len(m) > 2 else m

def get_cat(m):
    k = kind(m)
    if k.startswith('gpt-') or k.startswith('o'): return 'GPT'
    if k.startswith('claude-') or k.startswith('sonnet') or k.startswith('haiku'): return 'Claude'
    if k.startswith('deepseek'): return 'DeepSeek'
    if k.startswith('qwen'): return 'Qwen'
    if k.startswith('grok'): return 'Grok'
    if k.startswith('kimi') or k.startswith('moonshot'): return 'Moonshot'
    if k.startswith('llama'): return 'Llama'
    if k.startswith('mistral') or k.startswith('mixtral'): return 'Mistral'
    if k.startswith('gemin'): return 'Gemini'
    if 'step' in k.lower(): return 'Stepfun'
    return 'Other'

def sort_key(m):
    return (m.startswith('a-'), m)

cats = {}
for m in models:
    cat = get_cat(m)
    cats.setdefault(cat, []).append(m)

order = {'GPT':1,'Claude':2,'DeepSeek':3,'Grok':4,'Qwen':5,'Gemini':6,'Moonshot':7,'Llama':8,'Mistral':9,'Stepfun':10,'Other':99}
verbose = $verbose
for cat in sorted(cats.keys(), key=lambda c: order.get(c,99)):
    if verbose:
        print(f'  [{cat}]')
        for m in sorted(cats[cat], key=sort_key):
            print(f'    {m}')
    else:
        print(f'{cat}: ' + '  '.join(sorted(cats[cat], key=sort_key)))
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
# Remove stale modelOverrides entries (new Claude Code schema rejects object values)
# Unknown-model window enforcement is disabled via env var below (supported by all versions).
if model in d.get('modelOverrides',{}):
    del d['modelOverrides'][model]
if not d.get('modelOverrides',{}):
    d.pop('modelOverrides',None)
# Suppress 'unknown model' context-window warning
d['env']['CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT']='1'
existing=set(d.get('availableModels',[]))
existing.add(model)
d['availableModels']=sorted(existing)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"

  if ! echo "$json" | __cc_save_settings; then
    return 1
  fi

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
    # No taskModels configured — run auto-assign (shows its own progress to stderr)
    echo "[cc-run] No taskModels — auto-discovering models:"
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

    # Determine category with zsh-native matching (fast, no subshell per model)
    local cat
    case "$model" in
      gpt-*)    cat="GPT" ;;
      claude-*|sonnet*|haiku*) cat="Claude" ;;
      deepseek*) cat="DeepSeek" ;;
      qwen*)    cat="Qwen" ;;
      grok*)    cat="Grok" ;;
      *)        cat="Other" ;;
    esac

    local fallback="" _mcat
    # Build sorted model list from JSON (single python3 call)
    local models_str
    models_str="$(echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in sorted(d.get('availableModels',[]) or []):
    print(m)
")"

    local same_cat_list="" other_list=""
    while IFS= read -r m; do
      [[ -z "$m" || "$m" == "$model" ]] && continue
      _mcat="Other"
      case "$m" in
        gpt-*)    _mcat="GPT" ;;
        claude-*|sonnet*|haiku*) _mcat="Claude" ;;
        deepseek*) _mcat="DeepSeek" ;;
        qwen*)    _mcat="Qwen" ;;
        grok*)    _mcat="Grok" ;;
      esac
      [[ "$_mcat" == "$cat" ]] && same_cat_list+="$m"$'\n' || other_list+="$m"$'\n'
    done <<< "$models_str"

    # Probe same-category first, then others
    local full_list="${same_cat_list}${other_list}"
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      unset "__cc_health_cache[$m]"
      if __cc_test_model_health "$m" 5; then fallback="$m"; break; fi
    done <<< "$full_list"

    if [[ -n "$fallback" ]]; then
      echo "[cc-run] Fallback to: $fallback"
      model="$fallback"
    else
      echo "[cc-run] No healthy fallback found. Launching anyway..."
    fi
  fi

  # Launch Claude Code directly (skip cc()'s redundant health check)
  echo "[cc-run] Launching Claude Code with model: $model"

  local json2
  json2="$(__cc_read_settings)" || return 1

  # Atomic model switch
  json2="$(echo "$json2" | python3 -c "
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
# Remove stale modelOverrides (new Claude Code schema rejects object values)
if model in d.get('modelOverrides',{}):
    del d['modelOverrides'][model]
if not d.get('modelOverrides',{}):
    d.pop('modelOverrides',None)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
  if ! echo "$json2" | __cc_save_settings; then
    return 1
  fi

  local claude_bin
  claude_bin="$(__cc_find_claude)"
  if [[ -z "$claude_bin" ]]; then
    echo "Error: claude not found. Install with: npm install -g @anthropic-ai/claude-code" >&2
    return 1
  fi

  CC_SWITCH_SKIP_ENV=0 __cc_load_env

  local auth_key=""
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    auth_key="$ANTHROPIC_AUTH_TOKEN"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth_key="$ANTHROPIC_API_KEY"
  else
    auth_key="$(echo "$json2" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_AUTH_TOKEN','')")"
    [[ -z "$auth_key" ]] && auth_key="$(echo "$json2" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_API_KEY','')")"
  fi

  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    export ANTHROPIC_BASE_URL
  else
    local fallback_url
    fallback_url="$(echo "$json2" | __cc_json_get "d.get('env',{}).get('ANTHROPIC_BASE_URL','')")"
    [[ -n "$fallback_url" ]] && export ANTHROPIC_BASE_URL="$fallback_url"
  fi

  if [[ -n "$auth_key" ]]; then
    unset ANTHROPIC_API_KEY
    export ANTHROPIC_AUTH_TOKEN="$auth_key"
  fi

  eval "$claude_bin"
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
    echo "$json" | __cc_save_settings || return 1
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

  # Read-only failover: probe once, then test every model against the endpoint that
  # actually answers. __cc_test_model_health prefers CC_ACTIVE_* over the raw env.
  # Kept out of a subshell so the CC_LAST_CPA_* globals survive.
  CC_ACTIVE_BASE_URL=""
  CC_ACTIVE_API_KEY=""
  if __cc_fetch_cpa_models >/dev/null 2>&1; then
    CC_ACTIVE_BASE_URL="$CC_LAST_CPA_ENDPOINT"
    CC_ACTIVE_API_KEY="$CC_LAST_CPA_API_KEY"
  fi

  echo ""
  echo "=== Model Health Test ==="
  if [[ -n "$CC_ACTIVE_BASE_URL" ]]; then
    echo "  Endpoint: $CC_ACTIVE_BASE_URL"
    [[ "$CC_LAST_CPA_ENDPOINT_LABEL" != "primary" ]] && \
      echo "  Fallback: $CC_LAST_CPA_ENDPOINT_LABEL - primary endpoint did not answer"
  else
    echo "  Warning : no endpoint answered the probe; testing the primary only"
  fi
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
      api_key="${CC_ACTIVE_API_KEY:-${ep_raw##*|}}"
      base_url="${CC_ACTIVE_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
      [[ -z "$base_url" ]] && base_url="${ep_raw%|*}"
      base_url="${base_url%/v1/models}"
      base_url="${base_url%/}"
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
    echo "$json" | __cc_save_settings || return 1
    echo "Done. Run 'cc-sync' to re-fetch from CPA."
  fi

  echo ""
  echo "Tip: cc-test -RemoveDead    Remove failed models"

  # Do not leak the probe result into later commands (cc / cc-sync resolve their own).
  CC_ACTIVE_BASE_URL=""
  CC_ACTIVE_API_KEY=""
}

# === CPA ENDPOINT SWITCHING ===
# Switch between local / remote CPA endpoints by writing ~/.claude/current_endpoint.json.
# The shim (8316) reads this file dynamically per request, so no restart is needed.
# Real endpoint URLs and keys live in ~/.claude/cpa-endpoints.json (600, gitignored).
CC_ENDPOINT_FILE="$HOME/.claude/current_endpoint.json"
CC_ENDPOINTS_DB="$HOME/.claude/cpa-endpoints.json"

__cc_switch_endpoint() {
  local name="$1" url="$2" epkey="$3"
  umask 077
  cat > "$CC_ENDPOINT_FILE" <<JSON
{"name":"$name","url":"$url","key":"$epkey"}
JSON
  echo "[OK]  Endpoint switched -> $name"
  echo "  URL: $url"
  [[ -n "$epkey" ]] && echo "  Auth: remote key (from cpa-endpoints.json)" || echo "  Auth: local config.yaml key"
}

__cc_read_endpoint() {
  local name="$1"
  if [[ ! -f "$CC_ENDPOINTS_DB" ]]; then
    echo "Error: $CC_ENDPOINTS_DB not found. Create it with your endpoint URLs and keys." >&2
    return 1
  fi
  local entry
  entry="$(python3 -c "
import json, sys
try:
    d = json.load(open('$CC_ENDPOINTS_DB'))
    e = d.get('$name')
    if e: print(json.dumps(e))
except Exception: pass
" 2>/dev/null)"
  if [[ -z "$entry" ]]; then
    echo "Error: endpoint '$name' not found in $CC_ENDPOINTS_DB" >&2
    return 1
  fi
  echo "$entry"
}

cc-orcl() {
  local entry
  entry="$(__cc_read_endpoint "orcl")" || return 1
  local url key
  url="$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")"
  key="$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))")"
  __cc_switch_endpoint "orcl" "$url" "$key"
}

cc-aws() {
  local entry
  entry="$(__cc_read_endpoint "aws")" || return 1
  local url key
  url="$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")"
  key="$(echo "$entry" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))")"
  __cc_switch_endpoint "aws" "$url" "$key"
}

cc-local() {
  __cc_switch_endpoint "local" "http://127.0.0.1:8317" ""
}

cc-endpoint() {
  if [[ -f "$CC_ENDPOINT_FILE" ]]; then
    echo "=== Current CPA Endpoint ==="
    cat "$CC_ENDPOINT_FILE"
  else
    echo "No endpoint file. Using default: local (http://127.0.0.1:8317)"
  fi
}

# === CPA SYNC ===
# RIC-1845: the provider's raw model ID is the unit of comparison everywhere in
# this function. a-deepseek-flash and deepseek-flash are two independent entries
# with independent existence, selection and removal. A canonical_id is shown for
# context only and never replaces the raw ID.
cc-sync() {
  local list_mode=0 raw_list_mode=0 force=0 remove=0 reassign=0 health_mode=0
  local remove_id=""

  for arg in "$@"; do
    case "$arg" in
      -List|--list) list_mode=1 ;;
      -ListRaw|--list-raw) raw_list_mode=1 ;;
      -Force|--force) force=1 ;;
      -Remove|--remove) remove=1 ;;
      -Reassign|--reassign) reassign=1 ;;
      -Health|--health) health_mode=1 ;;
      -Id=*|--id=*) remove_id="${arg#*=}" ;;
    esac
  done

  # Primary endpoint first, then $CPA_FALLBACK_URLS (see __cc_fetch_cpa_models)
  local ep_raw
  ep_raw="$(__cc_resolve_endpoint)"
  local api_key="${ep_raw##*|}"
  local cpa_url="${ep_raw%|*}"

  if [[ -z "$cpa_url" || -z "$api_key" ]]; then
    echo "Error: no CPA endpoint / API key found." >&2
    echo "  Looked in: shell env → $CC_ENV_PATH → ${HOME}/.openclaw/.env → $CC_SETTINGS_PATH" >&2
    echo "  Fix (recommended) — add both lines to $CC_ENV_PATH:" >&2
    echo "    CPA_MODELS_URL=https://your-cpa-proxy/v1/models" >&2
    echo "    CPA_API_KEY=<your-cpa-key>" >&2
    echo "  Optional backup: CPA_FALLBACK_URLS=http://host:3000/v1[;http://other:3000]" >&2
    echo "  Then re-run: cc-sync" >&2
    return 1
  fi

  echo "Fetching models from CPA..."
  echo "  ${cpa_url%/v1/models}"

  # Raw provider IDs, verbatim — no alias rewrite, no prefix filtering.
  # No command substitution here: it would run the fetch in a subshell and lose the
  # CC_LAST_CPA_* globals that say which endpoint answered.
  local cpa_models models_file
  models_file="$(mktemp 2>/dev/null || echo "/tmp/.cc_models_out.$$")"
  if ! __cc_fetch_cpa_models > "$models_file"; then
    rm -f "$models_file" 2>/dev/null
    echo "Error fetching CPA models: no reachable endpoint." >&2
    return 1
  fi
  cpa_models="$(cat "$models_file")"
  rm -f "$models_file" 2>/dev/null
  if [[ "$CC_LAST_CPA_ENDPOINT_LABEL" != "primary" ]]; then
    echo "  Primary endpoint did not answer - using $CC_LAST_CPA_ENDPOINT_LABEL: $CC_LAST_CPA_ENDPOINT"
  fi
  [[ -z "$cpa_models" ]] && { echo "Error: CPA returned no models." >&2; return 1; }

  local count
  count="$(echo "$cpa_models" | wc -l | tr -d ' ')"
  echo "  Got $count models from CPA"

  # Raw + canonical identity view (raw_id is authoritative).
  local identities
  identities="$(echo "$cpa_models" | __cc_model_identity)"

  local cpa_a_count
  cpa_a_count="$(echo "$cpa_models" | grep -c '^a-' || true)"

  if [[ "$raw_list_mode" -eq 1 ]]; then
    echo ""
    echo "=== CPA Models — raw ID / canonical ID ($count) ==="
    echo "$identities" | while IFS=$'\t' read -r raw canon; do
      [[ -z "$raw" ]] && continue
      if [[ "$raw" == "$canon" ]]; then
        printf '  %s\n' "$raw"
      else
        printf '  %s  (canonical: %s)\n' "$raw" "$canon"
      fi
    done
    echo ""
    echo "--- $count models (${cpa_a_count} with 'a-' prefix) ---"
    return 0
  fi

  if [[ "$list_mode" -eq 1 ]]; then
    echo ""
    echo "=== CPA Models ($count) ==="
    echo "$cpa_models" | while IFS= read -r m; do echo "  $m"; done
    echo ""
    echo "--- $count models (${cpa_a_count} with 'a-' prefix) ---"
    return 0
  fi

  if [[ "$health_mode" -eq 1 ]]; then
    local health_ids="$identities"
    if [[ -n "$remove_id" ]]; then
      # --health --id=<raw_id>[,<raw_id>...] probes just those raw IDs.
      health_ids="$(printf '%s\n' "$remove_id" | tr ',' '\n' | sed '/^$/d')"
    fi
    __cc_sync_health_report "$health_ids"
    return $?
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

  # Membership tests are exact-string against the RAW CPA ID set. A model that
  # exists locally only under a bare name is NOT satisfied by an 'a-' ID in CPA.
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
  local local_count="$(echo "$local_models" | sed '/^$/d' | wc -l | tr -d ' ')"

  # --remove --id=<raw_id>: targeted removal of exactly one obsolete entry.
  if [[ "$remove" -eq 1 && -n "$remove_id" ]]; then
    if echo "$cpa_models" | grep -Fxq "$remove_id"; then
      echo "[SKIP] '$remove_id' is still served by CPA — not obsolete, not removed."
      return 0
    fi
    if ! echo "$local_models" | grep -Fxq "$remove_id"; then
      echo "[SKIP] '$remove_id' is not in availableModels — nothing to remove."
      return 0
    fi
    json="$(echo "$json" | CC_REMOVE_ID="$remove_id" python3 -c "
import json,sys,os
d=json.load(sys.stdin)
rid=os.environ['CC_REMOVE_ID']
d['availableModels']=[m for m in d.get('availableModels',[]) if m != rid]
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
    echo "$json" | __cc_save_settings || return 1
    echo "[OK]  Removed '$remove_id' from availableModels."
    return 0
  fi

  echo ""
  echo "=== CPA Sync Report ==="
  echo "  CPA total : $count (${cpa_a_count} with 'a-' prefix)"
  echo "  Local     : $local_count"
  [[ "$new_count" -gt 0 ]] && echo "  New       : +$new_count (not yet in local)"
  [[ "$gone_count" -gt 0 ]] && echo "  Gone      : -$gone_count (removed from CPA)"

  # Explicitly surface a- IDs so they can never be mistaken for absent.
  if [[ "$cpa_a_count" -gt 0 ]]; then
    echo ""
    echo "  'a-' models served by CPA (kept as distinct IDs):"
    echo "$cpa_models" | grep '^a-' | while IFS= read -r m; do
      if echo "$local_models" | grep -Fxq "$m"; then
        echo "    = $m"
      else
        echo "    + $m (new)"
      fi
    done
  fi

  echo ""
  echo "=== CPA Model List ==="

  echo "$cpa_models" | __cc_categorize_models --verbose

  echo ""
  if [[ -t 0 ]]; then
    echo -n "Press Enter to continue, or type 'q' to cancel sync: "
    read -r choice
    if [[ "$choice" == "q" ]]; then
      echo "Sync cancelled."
      return 0
    fi
  else
    # Non-interactive (fixture/CI): never block on a prompt.
    echo "  [non-interactive] no prompt; continuing"
  fi

  if [[ -n "$(echo "$new_models" | sed '/^$/d')" ]]; then
    echo ""
    echo "New models available:"
    echo "$new_models" | sed '/^$/d' | while IFS= read -r m; do echo "  + $m"; done

    local add=0
    if [[ "$force" -eq 1 ]]; then
      add=1
    elif [[ -t 0 ]]; then
      echo ""
      echo -n "Add these to local list? [Y/n] "
      read -r choice
      add=1
      [[ "$choice" == "n" || "$choice" == "N" ]] && add=0
    else
      add=0
      echo "  (non-interactive) not adding; use --force to merge"
    fi

    if [[ "$add" -eq 1 ]]; then
      # Merge as an exact set union of raw IDs. Distinct IDs stay distinct.
      json="$(echo "$json" | CC_NEW_MODELS="$new_models" python3 -c "
import json,sys,os
d=json.load(sys.stdin)
existing=set(d.get('availableModels',[]))
for m in os.environ.get('CC_NEW_MODELS','').split('\n'):
    m=m.strip()
    if m:
        existing.add(m)
d['availableModels']=sorted(existing)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      if ! echo "$json" | __cc_save_settings; then
        return 1
      fi
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
      # Obsolete == absent from CPA under its OWN raw ID. Nothing else is dropped.
      json="$(echo "$json" | CC_CPA_MODELS="$cpa_models" python3 -c "
import json,sys,os
d=json.load(sys.stdin)
cpa_set=set(m.strip() for m in os.environ.get('CC_CPA_MODELS','').split('\n') if m.strip())
local=d.get('availableModels',[])
d['availableModels']=sorted(m for m in local if m in cpa_set)
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)
")"
      if ! echo "$json" | __cc_save_settings; then
        return 1
      fi
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
  echo "Tip: cc-sync --list       -- raw model ID list"
  echo "Tip: cc-sync --list-raw   -- raw ID + canonical ID view"
  echo "Tip: cc-sync --force      -- auto-add new models"
  echo "Tip: cc-sync --remove     -- remove obsolete models"
  echo "Tip: cc-sync --remove --id=<raw_id>  -- remove one specific obsolete model"
  echo "Tip: cc-sync --health     -- probe every CPA raw ID, record HTTP status"
  echo "Tip: cc-sync --reassign   -- sync + reassign task models"
}

# Probe CPA raw IDs through the real Claude/CPA endpoint (POST /v1/messages)
# and record raw_id / HTTP status / error class. Prefix is irrelevant to routing:
# every ID listed is actually dialed, a- or not.
__cc_sync_health_report() {
  local ids="$1"
  local raw healthy=0 failed=0 total=0
  local failed_list=""

  echo ""
  echo "=== CPA Model Health (raw ID) ==="
  while IFS=$'\t' read -r raw _canon; do
    [[ -z "$raw" ]] && continue
    total=$((total + 1))
    unset "__cc_health_cache[$raw]"
    if __cc_test_model_health "$raw" 10; then
      healthy=$((healthy + 1))
      printf '  [OK]   %-42s HTTP %s\n' "$raw" "${CC_LAST_HEALTH_STATUS:-200}"
    else
      failed=$((failed + 1))
      failed_list="$failed_list$raw"$'\n'
      printf '  [FAIL] %-42s HTTP %s (%s)\n' "$raw" "${CC_LAST_HEALTH_STATUS:-000}" "${CC_LAST_HEALTH_CLASS:-unknown}"
    fi
  done <<< "$ids"

  echo ""
  echo "  Total   : $total"
  echo "  Healthy : $healthy"
  echo "  Failed  : $failed"
  [[ -n "${CC_HEALTH_LOG:-}" ]] && echo "  Evidence: $CC_HEALTH_LOG"

  if [[ "$failed" -gt 0 ]]; then
    echo ""
    echo "  Failed IDs (prefix is not a skip reason — each was actually probed):"
    echo "$failed_list" | sed '/^$/d' | while IFS= read -r m; do echo "    - $m"; done
    return 1
  fi
  return 0
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
  echo "$json" | __cc_save_settings || return 1
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
    # RIC-1851: json.dump emits no trailing newline, so the marker used to be
    # glued to the closing brace ('}REMOVED') and never matched '^REMOVED$'.
    # Terminate the JSON line first so the caller can detect and strip it.
    sys.stdout.write('\n')
    print('REMOVED')
else:
    print('NOT_FOUND')
")"

  if echo "$json" | grep -q "^REMOVED$"; then
    # RIC-1851: `head -n -1` is a GNU extension; on macOS BSD head it fails with
    # "illegal line count" and the save silently becomes a no-op. sed '$d' drops
    # the trailing marker portably.
    if ! echo "$json" | sed '$d' | __cc_save_settings; then
      return 1
    fi
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
      echo "$json" | __cc_save_settings || return 1
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
      echo "$json" | __cc_save_settings || return 1
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
      echo "$json" | __cc_save_settings || return 1
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
  echo "    cc-sync --list    Show full CPA model list (raw IDs)"
  echo "    cc-sync --list-raw  Raw ID + canonical ID view"
  echo "    cc-sync --force   Auto-add new models"
  echo "    cc-sync --remove  Remove obsolete models"
  echo "    cc-sync --health  Probe every CPA raw ID"
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
