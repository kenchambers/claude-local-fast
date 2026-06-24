# ════════════════════════════════════════════════════════════════════
# claude-local-fast — fast local Claude Code on Qwen3 4B (Ollama), 8GB M1
# ════════════════════════════════════════════════════════════════════
# Sourced from your shell rc by install/install_shell.sh, which also exports
# CLAUDE_LOCAL_FAST_DIR (the repo clone path). Everything in this file is
# resolved relative to that dir, so `git pull` updates the launchers, the
# proxy, the Modelfiles, and the settings together.
#
# Model: Qwen3 4B Instruct 2507 (q4_K_M, ~2.5GB) — the most capable model that
# fits an 8GB M1 *with* a usable context window. Served by Ollama's native
# Anthropic Messages API, so Claude Code talks to it with no proxy.
#
#   claude-local        everyday FAST local use (→ claude-local-medium, ~5k prompt)
#   claude-local-full   complete built-in tool set, slow first turn (~28k prompt)
#   claude-code         minimal 6-tool agent (~3k prompt), fastest
#   claude-air          FAST airplane (→ claude-air-fast, 8 tools, offline, ~4k)
#   claude-air-full     airplane, complete offline tool set (~28k prompt)
#   claude-ollama-reset force-restart Ollama if it hangs mid-session
#   claude-local-probe / -prefix-diff / -probe-stop   measure prefix stability
#
# Why not 64k ctx: a 64k KV cache (~4.6GB) + 2.5GB weights overcommits the
# ~5.3GB usable on an 8GB M1 and spills to CPU — slow, hot, battery drain.
# 16–32k keeps the model 100% on the GPU. Verify residency with:  ollama ps
#
# Offline hardening (so nothing hangs at 35,000 ft):
#   • 127.0.0.1 everywhere — 'localhost' resolves IPv6-first on macOS -> stall
#   • opus/sonnet/haiku tiers all mapped to the local tag, or background
#     calls 404 and look like a hang (the #1 offline trap)
#   • dummy auth token + API key unset -> no online credential validation
#   • telemetry / auto-update / error-report / non-essential model calls off
#
# Env is set INLINE per-command, so plain `claude` still uses cloud Anthropic
# and any custom routing you have is untouched.

# The installer exports this; refuse to define half-broken launchers without it.
: "${CLAUDE_LOCAL_FAST_DIR:?source claude-local-fast.zsh via install/install_shell.sh (it exports CLAUDE_LOCAL_FAST_DIR)}"

# Probe/proxy scratch dir (overridable). macOS sets TMPDIR; fall back to /tmp.
: "${CLAUDE_LOCAL_FAST_PROBE_LOG:=${TMPDIR:-/tmp}/cc_proxy}"

# Friendly error if Claude Code isn't installed yet (don't hardcode its path).
_claude_local_require_claude() {
    command -v claude >/dev/null 2>&1 && return 0
    echo "❌ 'claude' (Claude Code) is not on your PATH." >&2
    echo "   Run the installer:  \"\$CLAUDE_LOCAL_FAST_DIR/setup.sh\"" >&2
    echo "   or:  npm install -g @anthropic-ai/claude-code" >&2
    return 1
}

# Ensure an Ollama server is running with the 8GB-tuned, offline-safe env.
_ollama_serve_tuned() {
    export OLLAMA_HOST=127.0.0.1:11434       # IPv4 loopback only (offline-safe)
    export OLLAMA_FLASH_ATTENTION=1          # precondition for KV quantization
    export OLLAMA_KV_CACHE_TYPE=q8_0         # half-size KV cache, ~no quality loss
    export OLLAMA_NUM_PARALLEL=1             # RAM = NUM_PARALLEL * ctx — keep at 1
    export OLLAMA_MAX_LOADED_MODELS=1        # never co-resident a 2nd model on 8GB
    export OLLAMA_KEEP_ALIVE=5m              # unload after 5m idle (frees ~4GB RAM on 8GB M1)
    export OLLAMA_NO_CLOUD=1                 # never reach ollama.com for cloud models
    if ! command -v ollama >/dev/null 2>&1; then
        echo "❌ 'ollama' is not on your PATH. Run \"\$CLAUDE_LOCAL_FAST_DIR/setup.sh\" or: brew install ollama" >&2
        return 1
    fi
    local opid; opid="$(pgrep -x ollama 2>/dev/null | head -1)"
    if [ -z "$opid" ] || ! ps eww "$opid" 2>/dev/null | grep -q "OLLAMA_KV_CACHE_TYPE=q8_0"; then
        [ -n "$opid" ] && { echo "🔄 Restarting Ollama with tuned settings…"; pkill -x ollama; sleep 1; }
        nohup ollama serve >"${TMPDIR:-/tmp}/ollama_serve.log" 2>&1 &
        local t=0
        until curl -s http://127.0.0.1:11434/api/version >/dev/null 2>&1; do
            sleep 1; t=$((t+1))
            [ "$t" -ge 20 ] && { echo "❌ Ollama didn't start — see ${TMPDIR:-/tmp}/ollama_serve.log"; return 1; }
        done
    fi
}

# Build a tuned model tag from its Modelfile if it doesn't exist yet.
# `ollama list` reports created tags as "<tag>:latest", so strip that suffix
# before matching — otherwise we'd needlessly rebuild on every launch.
_ensure_ollama_model() {   # $1=tag  $2=modelfile
    ollama list 2>/dev/null | awk '{print $1}' | sed 's/:latest$//' | grep -qx "$1" && return 0
    echo "⚙️  Building $1 (one-time)…"
    ollama create "$1" -f "$2"
}

# ────────────────────────────────────────────────────────────────────
# Prefix-KV reuse: the cc_proxy forward+normalize "reuse proxy"
# ────────────────────────────────────────────────────────────────────
# Claude Code injects a per-request `cch` nonce in an anthropic-billing-header at
# the FRONT of the system prompt, which busts Ollama's prefix-KV cache every turn
# (even on the fast medium profile). cc_proxy.py in forward+normalize mode rewrites
# that nonce to a constant so the prefix is byte-stable and Ollama reuses it —
# measured ~20s/turn saved on warm medium turns (prefill-only collapse ~78x).
#
# Default: ON for the AIRPLANE launchers (in flight, prefill is pure battery-burning
# compute and the reuse proxy is localhost-only, so reuse is a free win), OPT-IN for
# the online launchers (set CLAUDE_LOCAL_FAST_NORMALIZE=1 — held opt-in to burn the
# proxy in as a reliability surface). CLAUDE_LOCAL_FAST_NORMALIZE, when set, wins
# either way: 0/false/no/off forces it OFF (even on airplane), 1/true/yes/on forces
# it ON. Port 11436 (the probe uses 11435; keep them distinct so a probe never
# reuses a forwarding proxy and loads the model).
typeset -g _CLAUDE_LOCAL_FAST_OWNS_PROXY=0

# Decide whether THIS launch routes through the reuse proxy. $1 is the per-launcher
# default (0|1) used only when CLAUDE_LOCAL_FAST_NORMALIZE is unset/empty; an
# explicit env value always overrides it (so `=0` is a real opt-out, unlike a bare
# -n test which treats "0" as set/true).
_claude_local_normalize_on() {   # $1 = default (0|1) when env unset/empty
    local v="${CLAUDE_LOCAL_FAST_NORMALIZE:-}"
    [ -z "$v" ] && v="${1:-0}"
    case "$v" in (1|true|TRUE|yes|YES|on|ON) return 0 ;; (*) return 1 ;; esac
}
_claude_local_ensure_reuse_proxy() {
    local PORT=11436
    curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 || { echo "⚠️  python3 missing — can't start the reuse proxy; using Ollama directly (no reuse)." >&2; return 1; }
    echo "🔁 reuse proxy: cc_proxy forward+normalize on 127.0.0.1:$PORT (strips the cch nonce → Ollama reuses the prefix)" >&2
    CC_PROXY_MODE=forward CC_PROXY_NORMALIZE=1 CC_PROXY_PORT=$PORT \
        CC_PROXY_UPSTREAM="http://127.0.0.1:11434" \
        CC_PROXY_LOG="$CLAUDE_LOCAL_FAST_PROBE_LOG" \
        nohup python3 "$CLAUDE_LOCAL_FAST_DIR/proxy/cc_proxy.py" >"${TMPDIR:-/tmp}/cc_proxy.fwd.log" 2>&1 &
    _CLAUDE_LOCAL_FAST_OWNS_PROXY=1
    local i
    for i in $(seq 1 20); do curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0; sleep 0.3; done
    echo "⚠️  reuse proxy didn't come up — using Ollama directly (no reuse). See ${TMPDIR:-/tmp}/cc_proxy.fwd.log" >&2
    return 1
}

# Stop the reuse proxy we started, on shell exit (tiny idle process, but it holds
# a port + RAM). Only the shell that started it does this.
_claude_local_stop_reuse_proxy() {
    [ "${_CLAUDE_LOCAL_FAST_OWNS_PROXY:-0}" = 1 ] || return 0
    pkill -f "$CLAUDE_LOCAL_FAST_DIR/proxy/cc_proxy.py" >/dev/null 2>&1
    _CLAUDE_LOCAL_FAST_OWNS_PROXY=0
}
autoload -Uz add-zsh-hook 2>/dev/null \
    && add-zsh-hook zshexit _claude_local_stop_reuse_proxy

# Launch full-profile Claude Code (ALL built-in tools) pointed at a local model.
_claude_local_launch() {   # $1=tag  $2=normalize-default(0|1) ; rest = claude args
    _claude_local_require_claude || return 1
    local MODEL="$1" NORM_DEFAULT="$2"; shift 2
    # Resolve the base URL inline (no subshell) so _claude_local_ensure_reuse_proxy
    # can background the proxy and set ownership in THIS shell, not a $() subshell.
    local BASE="http://127.0.0.1:11434"
    _claude_local_normalize_on "$NORM_DEFAULT" && _claude_local_ensure_reuse_proxy && BASE="http://127.0.0.1:11436"
    env -u ANTHROPIC_API_KEY \
        ANTHROPIC_BASE_URL="$BASE" \
        ANTHROPIC_AUTH_TOKEN="ollama" \
        ANTHROPIC_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS="1" \
        CLAUDE_CODE_DISABLE_TERMINAL_TITLE="1" \
        API_FORCE_IDLE_TIMEOUT="0" \
        MAX_THINKING_TOKENS="0" \
        CLAUDE_CODE_MAX_OUTPUT_TOKENS="8192" \
        claude --model "$MODEL" "$@"
}

# Launch Claude Code as a MINIMAL CUSTOM AGENT — swaps the huge base prompt for
# a tiny one and drops unused tool schemas (~28k → ~3-5k tokens). All trimming
# is PER-INVOCATION (--agent / --settings / --strict-mcp-config), so plain
# `claude` and the -full launchers are unaffected.
_claude_local_agent_launch() {   # $1=tag  $2=agent-name  $3=agents-json  $4=max-output  $5=normalize-default(0|1) ; rest=claude args
    _claude_local_require_claude || return 1
    local MODEL="$1" AGENT="$2" AGENTS="$3" MAXOUT="$4" NORM_DEFAULT="$5"; shift 5
    local BASE="http://127.0.0.1:11434"
    _claude_local_normalize_on "$NORM_DEFAULT" && _claude_local_ensure_reuse_proxy && BASE="http://127.0.0.1:11436"
    env -u ANTHROPIC_API_KEY \
        ANTHROPIC_BASE_URL="$BASE" \
        ANTHROPIC_AUTH_TOKEN="ollama" \
        ANTHROPIC_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS="1" \
        CLAUDE_CODE_DISABLE_TERMINAL_TITLE="1" \
        API_FORCE_IDLE_TIMEOUT="0" \
        MAX_THINKING_TOKENS="0" \
        CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAXOUT" \
        claude --model "$MODEL" \
               --settings "$CLAUDE_LOCAL_FAST_DIR/claude/settings.local-fast.json" \
               --strict-mcp-config \
               --agents "$AGENTS" \
               --agent "$AGENT" \
               "$@"
}

# ────────────────────────────────────────────────────────────────────
# Fast LOCAL launchers (custom agents)
# ────────────────────────────────────────────────────────────────────

# claude-code — minimal 6-tool agent (Read/Write/Edit/Bash/Grep/Glob), fastest.
# The ~2-min "hi" was prefill of Claude Code's ~28k-token system prompt (mostly
# built-in TOOL SCHEMAS, which a custom base-URL inlines in full) at ~120 tok/s.
claude-code() {
    _ollama_serve_tuned || return 1
    _ensure_ollama_model qwen3-cc "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.qwen3-cc" || return 1
    echo "⚡ claude-code → qwen3-cc  (Qwen3 4B · 12k ctx · minimal agent: Read/Write/Edit/Bash/Grep/Glob)"
    echo "   Prompt ~28k→~3.3k tokens (~27s vs ~2min). Plain 'claude'/'claude-local'/'claude-air' unaffected."
    local agents='{"local":{"description":"Fast local coding assistant","prompt":"You are a fast, concise on-device coding assistant running on a small local model. Be brief and direct. You have working file-system tools and you ARE inside the user repository. When asked anything about the repo, files, or code, you MUST first call a tool to inspect it (use Glob pattern **/* or Bash ls to list, Grep to search, Read to open). NEVER say you lack file access or ask the user to paste files; call a tool instead. Act via tool calls, not prose. Prefer Grep/Glob for search and keep explanations short.","tools":["Read","Write","Edit","Bash","Grep","Glob"]}}'
    _claude_local_agent_launch qwen3-cc local "$agents" 4096 0 "$@"   # 0 = reuse proxy opt-in
}

# claude-local-medium — 10-tool agent that ADDS WebFetch/WebSearch/TodoWrite/
# NotebookEdit on top of claude-code. Drops only the Task tool, whose schema
# alone costs +4,511 tokens (it inlines the whole agent-type catalog). Measured
# prompt ≈ 4,974 tokens vs ~25k full → ~40s cold prefill, near-instant warm.
claude-local-medium() {
    _ollama_serve_tuned || return 1
    _ensure_ollama_model qwen3-cc "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.qwen3-cc" || return 1
    echo "⚙️  claude-local-medium → qwen3-cc  (10 tools, no Task · ~5k-token prompt)"
    echo "   Read/Write/Edit/Bash/Grep/Glob + WebFetch/WebSearch/TodoWrite/NotebookEdit."
    local agents='{"medium":{"description":"Capable local coding assistant","prompt":"You are a capable on-device coding assistant running on a small local model. Be concise and direct. Use the tools to read, search, edit, write and run code, fetch web pages and search the web. You have working file-system tools and you ARE inside the user repository. When asked anything about the repo, files, or code, you MUST first call a tool to inspect it (use Glob pattern **/* or Bash ls to list, Grep to search, Read to open). NEVER say you lack file access or ask the user to paste files; call a tool instead. Act via tool calls, not prose. Keep explanations short.","tools":["Read","Write","Edit","Bash","Grep","Glob","WebFetch","WebSearch","TodoWrite","NotebookEdit"]}}'
    _claude_local_agent_launch qwen3-cc medium "$agents" 4096 0 "$@"   # 0 = reuse proxy opt-in
}

# claude-local-full — complete built-in tool set (~28k-token prompt, slow first
# turn). Kept for when you need every tool offline. Fast default: claude-local.
claude-local-full() {
    _ollama_serve_tuned || return 1
    _ensure_ollama_model qwen3-local "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.qwen3-local" || return 1
    echo "🤖 claude-local-full → qwen3-local  (Qwen3 4B · 16k ctx · ALL tools · ~2min first turn)"
    echo "   Plain 'claude' still uses cloud Anthropic.  Fast default: claude-local (→ medium)."
    _claude_local_launch qwen3-local 0 "$@"   # 0 = reuse proxy opt-in
}

# claude-local — FAST medium profile. As a function (not an alias) it can
# intercept --help and print the cheatsheet; other args pass through to medium.
claude-local() {
    case "$1" in
        -h|--h|--help)
            cat <<'CL_HELP'
claude-local — local Claude Code launchers (Qwen3-4B via Ollama, 8GB M1)

  COMMAND              WHAT IT IS                                   PROMPT     SPEED
  claude-local         → claude-local-medium (fast default)         ~5k tok    ~40s cold, near-instant warm
  claude-local-full    full profile, ALL tools (incl. Task)         ~28k tok   ~2min first turn
  claude-code          minimal 6-tool agent (Read/Write/Edit/...)   ~3k tok    fastest
  claude-air           → claude-air-fast (fast airplane, 8 tools)    ~4k tok    fast, offline
  claude-air-full      airplane, ALL tools incl. Task (offline)      ~28k tok   slow first turn
  claude               cloud Anthropic (untouched)                  —          cloud

  claude-local-medium       10 tools, no Task — what claude-local actually runs
  claude-local-probe        capture the REAL full prompt, NO model load (RAM-safe)
  claude-local-prefix-diff  diff two probed turns → will Ollama KV-reuse engage?
  claude-local-probe-stop   stop the probe proxy
  claude-ollama-reset       force-restart Ollama if it hangs mid-session

WHY medium is the default:
  • Full claude-local re-prefills a ~28k-token tool-schema prompt every turn at
    ~124 tok/s (~2 min). Medium = 10 tools, no Task (Task alone = +4,511 tokens)
    → ~4,974 tokens.
  • Ollama DOES reuse the prefix KV cache (~40x on turn 2) when the prompt prefix
    is byte-stable — check with claude-local-probe then claude-local-prefix-diff.
  • MLX is not faster on this M1. Reframe (arXiv 2509.07928 cascade): local for
    easy/offline turns, escalate heavy work to cloud `claude`.

KV-reuse:  airplane = ON by default · online = opt-in (CLAUDE_LOCAL_FAST_NORMALIZE=1)
  Claude Code injects a per-request `cch` nonce at the FRONT of the system prompt
  that busts Ollama prefix-KV reuse EVERY turn. The launchers route through cc_proxy
  (forward+normalize, localhost-only) which rewrites it to a constant → warm turns
  reuse the prefix (~20s/turn saved on medium; prefill-only collapse ~78x).
    • claude-air / claude-air-full → ON by default (in flight, prefill is just
      battery-burning compute; the proxy is localhost so it's offline-safe).
    • claude-local / -medium / -full / claude-code → set CLAUDE_LOCAL_FAST_NORMALIZE=1.
    • Force OFF anywhere (incl. airplane):  CLAUDE_LOCAL_FAST_NORMALIZE=0
  Watch it work:  grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"

Usage:  claude-local [claude args...]   |   claude-local --help   |   claude-local-full
CL_HELP
            return 0 ;;
    esac
    claude-local-medium "$@"
}

# ────────────────────────────────────────────────────────────────────
# Airplane launchers (offline > battery > speed)
# ────────────────────────────────────────────────────────────────────

# Warm the air model so the first real prompt pays no cold-load penalty.
_claude_air_warm() {
    curl -s http://127.0.0.1:11434/api/generate \
        -d '{"model":"qwen3-air","prompt":"","keep_alive":-1}' >/dev/null 2>&1
}

_claude_air_preflight() {
    echo "✈️  Pre-flight: Low Power Mode ON · brightness ~40% · quit Chrome/Docker,"
    echo "   confirm 'ollama list' shows qwen3-air, then Airplane Mode / Wi-Fi OFF."
}

# claude-air-fast — 8-tool agent (medium set minus WebFetch/WebSearch, since
# Wi-Fi is off in flight). ~4k prompt. What `claude-air` runs.
claude-air-fast() {
    _claude_air_preflight
    _ollama_serve_tuned || return 1
    _ensure_ollama_model qwen3-air "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.qwen3-air" || return 1
    _claude_air_warm
    echo "🛩️  claude-air-fast → qwen3-air  (8 tools, no Task/web · ~4k prompt · battery)"
    echo "   KV-reuse ON by default (cch nonce normalized via localhost proxy → ~20s/warm turn,"
    echo "   less battery). Disable with CLAUDE_LOCAL_FAST_NORMALIZE=0. Hangs? claude-ollama-reset"
    local agents='{"air":{"description":"Offline local coding assistant","prompt":"You are a capable on-device coding assistant running on a small local model with NO network access. Be concise and direct. You have working file-system tools and you ARE inside the user repository. When asked anything about the repo, files, or code, you MUST first call a tool to inspect it (use Glob pattern **/* or Bash ls to list, Grep to search, Read to open). NEVER say you lack file access or ask the user to paste files; call a tool instead. Act via tool calls, not prose. Keep explanations short.","tools":["Read","Write","Edit","Bash","Grep","Glob","TodoWrite","NotebookEdit"]}}'
    _claude_local_agent_launch qwen3-air air "$agents" 4096 1 "$@"   # 1 = reuse proxy default-on (battery)
}

# claude-air-full — complete offline tool set incl. Task (~28k prompt, slow
# first turn). Fast default: claude-air-fast.
claude-air-full() {
    _claude_air_preflight
    _ollama_serve_tuned || return 1
    _ensure_ollama_model qwen3-air "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.qwen3-air" || return 1
    _claude_air_warm
    echo "🛩️  claude-air-full → qwen3-air  (Qwen3 4B · 16k ctx · ALL tools · battery)"
    echo "   KV-reuse ON by default (cch nonce normalized via localhost proxy → reuses the ~28k"
    echo "   tool-schema prefix). Disable with CLAUDE_LOCAL_FAST_NORMALIZE=0. Hangs? claude-ollama-reset"
    _claude_local_launch qwen3-air 1 "$@"   # 1 = reuse proxy default-on (battery)
}

# claude-air → FAST airplane profile. --help prints the launcher cheatsheet.
claude-air() {
    case "$1" in
        -h|--h|--help) claude-local --help; return 0 ;;
    esac
    claude-air-fast "$@"
}

# ────────────────────────────────────────────────────────────────────
# Recovery + diagnostics
# ────────────────────────────────────────────────────────────────────

# Force-restart Ollama (clears the count_tokens stall, Ollama #13949).
claude-ollama-reset() {
    echo "🔧 Restarting Ollama…"; pkill -x ollama; sleep 2
    _ollama_serve_tuned && echo "✅ Ollama back up on 127.0.0.1:11434"
}

# claude-local-probe — run the REAL full claude-local profile through
# proxy/cc_proxy.py, which logs each request's static prefix (system+tools) and
# returns a canned reply WITHOUT loading the model (RAM-safe, instant). Send two
# prompts, Ctrl-C, then `claude-local-prefix-diff`.
claude-local-probe() {
    _claude_local_require_claude || return 1
    local PORT=11435 LOG="$CLAUDE_LOCAL_FAST_PROBE_LOG"
    mkdir -p "$LOG"; rm -f "$LOG"/turn_*.front.txt "$LOG"/turn_*.json "$LOG"/summary.log 2>/dev/null
    if ! curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
        echo "🔌 starting cc_proxy (probe mode, model-free) on 127.0.0.1:$PORT …"
        CC_PROXY_MODE=probe CC_PROXY_PORT=$PORT CC_PROXY_LOG="$LOG" \
            nohup python3 "$CLAUDE_LOCAL_FAST_DIR/proxy/cc_proxy.py" >"${TMPDIR:-/tmp}/cc_proxy.serverlog" 2>&1 &
        for i in $(seq 1 20); do curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.3; done
    fi
    echo "🧪 claude-local-probe → capturing the real full claude-local prompt (NO model load)."
    echo "   1) type a short prompt + enter   (instant '(probe)' reply)"
    echo "   2) type a SECOND prompt + enter  (instant reply)"
    echo "   3) Ctrl-C, then run:  claude-local-prefix-diff"
    env -u ANTHROPIC_API_KEY \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
        ANTHROPIC_AUTH_TOKEN="probe" \
        ANTHROPIC_MODEL="qwen3-local" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="qwen3-local" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="qwen3-local" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="qwen3-local" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS="1" \
        CLAUDE_CODE_DISABLE_TERMINAL_TITLE="1" \
        MAX_THINKING_TOKENS="0" \
        claude --model qwen3-local "$@"
}

# claude-local-prefix-diff — diff the two captured turns' static prefix.
# ✅ identical ⇒ Ollama KV reuse will engage; ❌ shows the busting bytes.
claude-local-prefix-diff() {
    local LOG="$CLAUDE_LOCAL_FAST_PROBE_LOG"
    local files=( "$LOG"/turn_*.front.txt(N) )
    (( ${#files} < 2 )) && { echo "Need ≥2 captured turns in $LOG — run claude-local-probe first."; return 1; }
    echo "=== captured requests ($LOG/summary.log) ==="; cat "$LOG/summary.log"; echo ""
    echo "=== prefix diff: $(basename ${files[1]}) vs $(basename ${files[2]}) ==="
    if diff -q "${files[1]}" "${files[2]}" >/dev/null; then
        echo "✅ IDENTICAL static prefix → Ollama WILL reuse the ~28k tool-schema KV on turn 2 (≈40x faster prefill)."
        echo "   Next: raise OLLAMA_KEEP_ALIVE so the slot stays warm and the win is automatic."
    else
        echo "❌ Prefix DIFFERS across turns → this is what busts KV reuse. First differences:"
        diff "${files[1]}" "${files[2]}" | head -40
        echo "   Fix = normalize the differing bytes in proxy/cc_proxy.py, then run it in forward mode."
    fi
}

# claude-local-probe-stop — stop the probe proxy.
claude-local-probe-stop() {
    pkill -f "$CLAUDE_LOCAL_FAST_DIR/proxy/cc_proxy.py" 2>/dev/null && echo "🛑 cc_proxy stopped." || echo "cc_proxy not running."
}
