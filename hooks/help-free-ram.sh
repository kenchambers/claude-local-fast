#!/bin/zsh
# help-free-ram.sh — OPTIONAL emergency RAM-free hook for 8GB Macs.
#
# UserPromptSubmit hook: when the user submits exactly "help" — an agreed
# distress signal that this 8GB Mac is about to crash — unload every loaded
# Ollama model to free RAM immediately. Opt-in: register it yourself in
# ~/.claude/settings.json (see docs/TROUBLESHOOTING.md); setup.sh never wires
# this in automatically.
#
# UserPromptSubmit exit semantics:
#   exit 0 + stdout  -> stdout injected as context, the prompt proceeds
#   exit 2 + stderr  -> the prompt is BLOCKED, stderr is shown to the user
#
# In a claude-local session we BLOCK (exit 2): otherwise the local model would
# immediately reload (~4GB) to answer "help", re-consuming the RAM we freed.
# In a cloud session we let it through (exit 0) so cloud Claude can confirm.

input="$(cat)"

# --- extract the submitted prompt ---
if command -v jq >/dev/null 2>&1; then
  prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
else
  prompt="$(printf '%s' "$input" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("prompt",""))' 2>/dev/null)"
fi

# --- normalize: lowercase, trim ends, drop trailing . or ! ---
norm="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[.!]+$//')"

# Not the distress word -> do nothing, let the prompt through untouched.
[ "$norm" = "help" ] || exit 0

# --- EMERGENCY: unload every loaded Ollama model to free RAM ---
freed=""
if command -v ollama >/dev/null 2>&1; then
  loaded="$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}')"
  if [ -n "$loaded" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      ollama stop "$m" >/dev/null 2>&1 && freed="${freed:+$freed, }$m"
    done <<EOF
$loaded
EOF
  fi
  pkill -f "ollama runner" >/dev/null 2>&1   # belt-and-suspenders for orphans
fi

freepct="$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{print $2}')"
msg="🚨 EMERGENCY RAM-FREE ran. Unloaded Ollama model(s): ${freed:-none were loaded}. Free RAM now: ${freepct:-unknown}."

# --- local session? block so the local model does not reload ---
case "$ANTHROPIC_BASE_URL" in
  *11434*|*localhost*|*127.0.0.1*)
    printf '%s\n' "$msg You're in claude-local — press Ctrl+C then type 'exit' to keep the RAM freed; don't keep prompting the local model until memory recovers." >&2
    exit 2
    ;;
  *)
    printf '%s\n' "$msg"
    exit 0
    ;;
esac
