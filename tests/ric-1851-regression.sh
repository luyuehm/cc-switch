#!/usr/bin/env bash
# Regression matrix for RIC-1845 (a- models are distinct IDs) and RIC-1851
# (CC_SETTINGS_PATH propagation, atomic write, failure gating, portable line
# handling).
#
# Every scenario runs against a throwaway HOME and a local mock of the CPA
# /v1/models endpoint, so nothing touches the real ~/.claude/settings.json and
# no network access is required. Ambient provider/model environment variables
# are stripped first: an inherited ANTHROPIC_BASE_URL would otherwise mask the
# fixture endpoint and make the results meaningless.
#
# Usage: ./tests/ric-1851-regression.sh [path-to-cc-switch.sh]
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cc-switch.sh"
[[ $# -ge 1 ]] && SCRIPT="$1"
if [[ ! -f "$SCRIPT" ]]; then
  echo "error: no such file: $SCRIPT" >&2
  exit 2
fi

PORT="${RIC_TEST_PORT:-18931}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ric1853-test.XXXXXX")"
MOCK_PID=""
PASS=0
FAIL=0

cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null
  chmod -R u+rwx "$ROOT" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ── Mock CPA endpoint ────────────────────────────────────────────────────
# Serves a fixed model list. a-deepseek-flash is deliberately served WITHOUT a
# bare deepseek-flash counterpart: that is what lets T2 prove the removal of
# the bare ID is an exact-string match and not a prefix collapse.
cat > "$ROOT/mock_cpa.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODELS = [{"id": "a-deepseek-flash"}, {"id": "gpt-5.3-codex"}]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": MODELS}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

python3 -I "$ROOT/mock_cpa.py" "$PORT" &
MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -sf --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! curl -sf --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
  echo "error: mock CPA endpoint failed to start on port $PORT" >&2
  exit 2
fi

# ── Helpers ──────────────────────────────────────────────────────────────
record() {
  if [[ "$2" == "PASS" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  printf '  %-56s %s  %s\n' "$1" "$2" "${3:-}"
}

new_sandbox() {
  SBX="$(mktemp -d "$ROOT/sbx.XXXXXX")"
  mkdir -p "$SBX/home/.claude" "$SBX/home/.openclaw"
  : > "$SBX/home/.openclaw/.env"
  SET="$SBX/home/.claude/settings.json"
}

clean_env() {
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
      -u ANTHROPIC_MODEL -u CPA_MODELS_URL -u CPA_API_KEY \
      -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL \
      -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u ANTHROPIC_REASONING_MODEL \
      -u ANTHROPIC_DEFAULT_OPUS_MODEL_NAME -u ANTHROPIC_DEFAULT_SONNET_MODEL_NAME \
      -u ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME \
      -u CC_SETTINGS_PATH -u CC_ENV_PATH -u CC_ALIAS_FILE -u CC_HEALTH_LOG \
      "$@"
}

run_fixture() {
  clean_env HOME="$SBX/home" ANTHROPIC_AUTH_TOKEN="fixture-token" \
    CPA_MODELS_URL="http://127.0.0.1:$PORT/v1/models" \
    bash -c '. "$1"; shift; eval "$*"' _ "$SCRIPT" "$1" 2>&1
}

models_of() {
  python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1])).get('availableModels',[])))" "$1" 2>/dev/null
}
rc_of() { printf '%s\n' "$1" | grep -o 'RC=[0-9]*' | tail -1; }

echo "=== cc-switch regression matrix: $SCRIPT ==="
echo ""

# ── T1: a- and bare IDs stay distinct through a save ─────────────────────
new_sandbox
printf '%s\n' '{"availableModels":[],"env":{}}' > "$SET"
OUT=$(run_fixture 'echo "{\"availableModels\":[\"a-deepseek-flash\",\"deepseek-flash\"],\"env\":{}}" | __cc_save_settings; echo "RC=$?"')
M=$(models_of "$SET")
if [[ "$(rc_of "$OUT")" == "RC=0" ]] \
   && printf '%s\n' "$M" | grep -Fxq 'a-deepseek-flash' \
   && printf '%s\n' "$M" | grep -Fxq 'deepseek-flash' \
   && [[ "$(printf '%s\n' "$M" | grep -c .)" -eq 2 ]]; then
  record "RIC-1845 a- and bare IDs independent on save" PASS "2 distinct entries, rc=0"
else
  record "RIC-1845 a- and bare IDs independent on save" FAIL "rc=$(rc_of "$OUT") got=$(printf '%s' "$M" | tr '\n' ',')"
fi

# ── T2: --remove --id compares the raw ID exactly ────────────────────────
new_sandbox
printf '%s\n' '{"availableModels":["a-deepseek-flash","deepseek-flash","stale-model"],"env":{}}' > "$SET"
OUT=$(run_fixture 'cc-sync --remove --id=deepseek-flash; echo "RC=$?"')
M=$(models_of "$SET")
if [[ "$(rc_of "$OUT")" == "RC=0" ]] \
   && printf '%s\n' "$M" | grep -Fxq 'a-deepseek-flash' \
   && ! printf '%s\n' "$M" | grep -Fxq 'deepseek-flash' \
   && printf '%s\n' "$M" | grep -Fxq 'stale-model'; then
  record "RIC-1845 --remove --id exact raw ID isolation" PASS "a- kept, bare removed"
else
  record "RIC-1845 --remove --id exact raw ID isolation" FAIL "rc=$(rc_of "$OUT") got=$(printf '%s' "$M" | tr '\n' ',')"
fi

# ── T3: CC_SETTINGS_PATH works when assigned but never exported ──────────
# This is the .zshrc case: the variable is a plain shell local, so the child
# Python cannot find it in os.environ and used to die with KeyError.
new_sandbox
ALT="$SBX/alt-settings.json"
printf '%s\n' '{"availableModels":["stale-model"],"env":{}}' > "$ALT"
OUT=$(run_fixture "CC_SETTINGS_PATH='$ALT'; echo '{\"availableModels\":[\"x-model\"],\"env\":{}}' | __cc_save_settings; echo \"RC=\$?\"")
M=$(models_of "$ALT")
if [[ "$(rc_of "$OUT")" == "RC=0" && "$(printf '%s' "$M")" == "x-model" ]]; then
  record "RIC-1851 CC_SETTINGS_PATH write without export" PASS "rc=0, alt path written"
else
  record "RIC-1851 CC_SETTINGS_PATH write without export" FAIL "rc=$(rc_of "$OUT") got=$(printf '%s' "$M" | tr '\n' ',')"
fi

# ── T4: an unwritable target returns nonzero and prints no fake [OK] ─────
# The read path succeeds (valid JSON in a read-only directory); only the write
# is denied, which isolates the failure gate from the KeyError above.
new_sandbox
RO="$SBX/ro"
mkdir -p "$RO"
printf '%s\n' '{"availableModels":["stale-model"],"env":{}}' > "$RO/settings.json"
chmod 500 "$RO"
OUT=$(run_fixture "export CC_SETTINGS_PATH='$RO/settings.json'; cc-sync --remove --id=stale-model; echo \"RC=\$?\"")
OKL=$(printf '%s\n' "$OUT" | grep -c '^\[OK\]')
chmod 700 "$RO"
M=$(models_of "$RO/settings.json")
if [[ "$(rc_of "$OUT")" != "RC=0" && "$OKL" -eq 0 && "$(printf '%s' "$M")" == "stale-model" ]]; then
  record "RIC-1851 unwritable target: nonzero, no fake [OK]" PASS "rc=$(rc_of "$OUT"), file untouched"
else
  record "RIC-1851 unwritable target: nonzero, no fake [OK]" FAIL "rc=$(rc_of "$OUT") ok_lines=$OKL file=$(printf '%s' "$M")"
fi

# ── T5: repeated sync is idempotent ─────────────────────────────────────
new_sandbox
printf '%s\n' '{"availableModels":[],"env":{}}' > "$SET"
for i in 1 2 3; do
  OUT=$(run_fixture 'cc-sync --force </dev/null; echo "RC=$?"')
  eval "H$i=$(shasum -a 256 "$SET" | cut -d' ' -f1)"
done
if [[ "$H1" == "$H2" && "$H2" == "$H3" && "$(rc_of "$OUT")" == "RC=0" ]]; then
  record "idempotent repeated sync" PASS "3 runs identical, rc=0"
else
  record "idempotent repeated sync" FAIL "rc=$(rc_of "$OUT") ${H1:0:8}/${H2:0:8}/${H3:0:8}"
fi

# ── T6: corrupt settings JSON is preserved, never overwritten ────────────
new_sandbox
printf '%s\n' '{ this is not json' > "$SET"
B=$(shasum -a 256 "$SET" | cut -d' ' -f1)
OUT=$(run_fixture '__cc_read_settings >/dev/null 2>&1; echo "RC=$?"')
A=$(shasum -a 256 "$SET" | cut -d' ' -f1)
if [[ "$(rc_of "$OUT")" != "RC=0" && "$B" == "$A" ]]; then
  record "RIC-1851 corrupt JSON preserved" PASS "rc=$(rc_of "$OUT"), bytes unchanged"
else
  record "RIC-1851 corrupt JSON preserved" FAIL "rc=$(rc_of "$OUT") preserved=$([[ $B == $A ]] && echo yes || echo no)"
fi

# ── T7: cc-show strips the trailing marker portably ─────────────────────
# `head -n -1` is a GNU extension; on BSD/macOS head the save used to become a
# silent no-op, so the override survived and nothing was restored.
new_sandbox
printf '%s\n' '{"availableModels":["m1"],"env":{},"skillOverrides":{"my-skill":"off"}}' > "$SET"
OUT=$(run_fixture 'cc-show my-skill; echo "RC=$?"')
ST=$(python3 -c "import json;d=json.load(open('$SET'));print('absent' if 'my-skill' not in (d.get('skillOverrides') or {}) else 'still-hidden')" 2>/dev/null)
if [[ "$(rc_of "$OUT")" == "RC=0" ]] \
   && printf '%s\n' "$OUT" | grep -q 'Restored: my-skill' \
   && [[ "$ST" == "absent" ]]; then
  record "RIC-1851 cc-show portable marker strip" PASS "restored, override gone"
else
  record "RIC-1851 cc-show portable marker strip" FAIL "rc=$(rc_of "$OUT") state=$ST"
fi

# ── T8: syntax ──────────────────────────────────────────────────────────
zsh -n "$SCRIPT" 2>/dev/null && record "syntax: zsh -n" PASS || record "syntax: zsh -n" FAIL
bash -n "$SCRIPT" 2>/dev/null && record "syntax: bash -n" PASS || record "syntax: bash -n" FAIL

echo ""
echo "=== SUMMARY  PASS=$PASS  FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
