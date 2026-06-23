#!/usr/bin/env bash
# tests/smoke.sh — model-free smoke tests. Runs locally and in CI (no Ollama,
# no Claude Code, no Apple-Silicon hardware required).
#
#   1. zsh -n on the launcher file
#   2. py_compile on the proxy
#   3. JSON validity of the settings file
#   4. probe self-test: drive cc_proxy.py in probe mode end-to-end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_0=$'\033[0m'; else C_G=''; C_R=''; C_0=''; fi
pass() { printf '%s\n' "${C_G}ok${C_0}   $*"; }
fail() { printf '%s\n' "${C_R}FAIL${C_0} $*" >&2; exit 1; }

# ---- 1. zsh syntax ----
if ! command -v zsh >/dev/null 2>&1; then
  fail "zsh not installed (required for the launcher syntax check)"
fi
if CLAUDE_LOCAL_FAST_DIR="$REPO" zsh -n "$REPO/shell/claude-local-fast.zsh"; then
  pass "zsh -n shell/claude-local-fast.zsh"
else
  fail "zsh -n shell/claude-local-fast.zsh"
fi

# ---- 2. proxy compiles ----
if python3 -m py_compile "$REPO/proxy/cc_proxy.py"; then
  pass "py_compile proxy/cc_proxy.py"
else
  fail "py_compile proxy/cc_proxy.py"
fi

# ---- 3. settings JSON valid ----
if python3 -c "import json; json.load(open('$REPO/claude/settings.local-fast.json'))"; then
  pass "json valid claude/settings.local-fast.json"
else
  fail "invalid JSON in claude/settings.local-fast.json"
fi

# ---- 4. probe self-test (model-free) ----
# Pick a free ephemeral port so the test is deterministic even if 11539 is busy.
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
LOG="$(mktemp -d "${TMPDIR:-/tmp}/clf_probe.XXXXXX")"
CC_PROXY_MODE=probe CC_PROXY_PORT="$PORT" CC_PROXY_LOG="$LOG" \
  python3 "$REPO/proxy/cc_proxy.py" >"$LOG/server.log" 2>&1 &
PROXY_PID=$!
disown "$PROXY_PID" 2>/dev/null || true   # keep bash from printing "Terminated" on cleanup
cleanup() { kill "$PROXY_PID" >/dev/null 2>&1 || true; wait "$PROXY_PID" 2>/dev/null || true; rm -rf "$LOG"; }
trap cleanup EXIT

# wait for health
ok=0
tries=0
while [ "$tries" -lt 40 ]; do
  if curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.25
  tries=$((tries + 1))
done
[ "$ok" = 1 ] || fail "cc_proxy did not start (see $LOG/server.log)"
pass "cc_proxy healthz responded on port $PORT"

REQ='{"model":"test","system":"sys","tools":[{"name":"Read"},{"name":"Bash"}],"messages":[{"role":"user","content":"hi"}]}'

# non-streaming
NS="$(curl -s -X POST "http://127.0.0.1:$PORT/v1/messages" \
       -H 'content-type: application/json' -d "$REQ")"
printf '%s' "$NS" | grep -q 'probe' || fail "non-streaming reply missing canned probe text: $NS"
pass "non-streaming /v1/messages returned canned reply"

# streaming
SS="$(curl -s -N -X POST "http://127.0.0.1:$PORT/v1/messages" \
       -H 'content-type: application/json' \
       -d '{"model":"test","stream":true,"tools":[{"name":"Read"}],"messages":[{"role":"user","content":"yo"}]}')"
printf '%s' "$SS" | grep -q 'message_start'        || fail "streaming reply missing message_start"
printf '%s' "$SS" | grep -q 'content_block_delta'  || fail "streaming reply missing content_block_delta"
pass "streaming /v1/messages returned an SSE event stream"

# count_tokens
CT="$(curl -s -X POST "http://127.0.0.1:$PORT/v1/messages/count_tokens" \
       -H 'content-type: application/json' -d "$REQ")"
printf '%s' "$CT" | grep -q 'input_tokens' || fail "count_tokens missing input_tokens: $CT"
pass "/v1/messages/count_tokens returned input_tokens"

# logs were written
[ -f "$LOG/turn_001.json" ] || fail "expected $LOG/turn_001.json"
[ -f "$LOG/turn_002.json" ] || fail "expected $LOG/turn_002.json"
python3 -c "
import json,sys
d1=json.load(open('$LOG/turn_001.json'))
d2=json.load(open('$LOG/turn_002.json'))
assert d1['num_tools']==2, d1
assert d1['tool_bytes']>0, d1
# prefix-stability telemetry contract (cache-hit precondition):
# turn 1 is the first tracked /v1/messages turn -> no prior to compare to.
assert d1.get('prefix_stable_vs_prev') is None, d1
# turn 2 compares against turn 1; the two requests differ -> prefix busted.
assert d2.get('prev_front_sha256')==d1['front_sha256'], (d1,d2)
assert d2.get('prefix_stable_vs_prev') is False, d2
print('turn_001: num_tools=%d tool_bytes=%d | stability telemetry present'%(d1['num_tools'],d1['tool_bytes']))
" || fail "turn_*.json did not contain the expected fingerprints + stability telemetry"
pass "probe logged turn_*.json with tool fingerprints + prefix-stability verdict"

printf '\n%sAll smoke tests passed.%s\n' "$C_G" "$C_0"
