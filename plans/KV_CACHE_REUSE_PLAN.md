# Plan: maximize KV-cache reuse across `claude-local-fast`'s agentic loops

**Status:** Phases 1–5 **done and measured** (2026-06-24). Phase 1 (grounding) +
telemetry shipped first; Phase 2 measurement then found a concrete prefix buster,
which justified and drove the Phase 4 normalizer; Phase 5 confirmed the win on the
real model. Numbers in [§ Measured results](#measured-results-2026-06-24).

> **Headline:** Claude Code injects an `anthropic-billing-header` with a per-request
> `cch=<hex>` nonce at the **front** of the system prompt that busts Ollama prefix-KV
> reuse on **every** turn — even on the fast `claude-local` (medium) default. The
> opt-in proxy normalizer (`CC_PROXY_NORMALIZE=1`) rewrites it to a constant,
> measured to collapse turn-2 prefill **27.5 s → 0.4 s (~78×)** on qwen3-cc.

> **Scope reconciliation.** The originating task was written for a generic
> multi-provider router (`cc_bridge.py`, MT5, OpenAI/Google/DeepSeek/vLLM…). **None
> of that exists here.** This repo is the *fast local half* of that idea: one real
> backend (local Ollama via `--agent` trim) plus an untouched cloud `claude`. So
> "maximize KV-cache reuse across agentic loops" here means **Ollama prefix-KV
> reuse**, measured and kept stable. Backend mechanics are grounded in
> [KV_CACHE_GROUNDING.md](KV_CACHE_GROUNDING.md).

---

## Operating thesis vs. what this repo already does

The thesis (order most-stable→least-stable; keep the front byte-identical;
append-only history; compaction is a cache-invalidation event) is **already largely
satisfied here, by construction** — which is *why* this repo works at all:

| Thesis requirement | Status in this repo |
|---|---|
| Shrink the re-prefilled prefix | ✅ `--agent` trims ~28k→~5k tokens (drops `Task` = −4,511 tok). |
| Stable, byte-identical system prefix | ✅ Agent system prompt is a **static inline JSON literal** per launcher (no timestamp/UUID/RNG). |
| Deterministic tool block | ✅ Fixed tool array per agent; `--strict-mcp-config` + settings disable plugins/skills/MCP. |
| Dynamic content at the tail | ✅ Claude Code puts date / CLAUDE.md / `<system-reminder>` in the **messages array, after** the tool block (per ARCHITECTURE.md); `settings.local-fast.json` excludes `**/CLAUDE.md`. |
| Append-only history | ✅ Claude Code's job; this repo doesn't reorder/edit. |
| No per-backend byte divergence within a session | ✅ opus/sonnet/haiku tiers all map to one local tag (no mid-session model switch). |

**The gap was never the design — it was *proof and observability*.** Nobody had
run-and-recorded that the prefix actually stays byte-stable turn-to-turn on the live
Ollama leg, and the cache-hit rate wasn't visible in normal operation. That is what
this plan closes.

---

## Phase 2 — Audit + baseline (the control group)

### Static audit: every prefix-instability source this repo controls

The assembly is mostly Claude Code's (closed). The bytes **this repo** can
destabilize, and their current state:

1. **Agent system prompt** (inline JSON in `shell/claude-local-fast.zsh`) — static
   literal. ✅ Stable. *Risk only if ever templated with a variable.*
2. **Tool list** (per-agent array) — fixed. Claude Code serializes the schemas;
   the open question is whether that serialization is **deterministic across turns**
   on the Ollama leg. → measured below.
3. **`settings.local-fast.json`** — static; excludes `**/CLAUDE.md`. ✅
4. **Per-turn dynamics** (date, CLAUDE.md, reminders) — placed at the tail by Claude
   Code. Known busters (ARCHITECTURE.md): date rollover changing an early token,
   non-deterministic schema serialization, or model unload between turns.
5. **Model-tier mapping** — all tiers → one tag (no second model, no mid-session
   switch). ✅
6. **Cross-launcher divergence** — `medium`/`code` (qwen3-cc) vs `air` (qwen3-air,
   8 tools) assemble *different* tool sets, but that is **by-profile design**, not
   accidental drift; within one launcher/session the prefix is fixed. ✅

**Finding:** the repo's controllable assembly is prefix-stable by construction. The
one thing requiring empirical proof is **#2/#4 on the live leg** — does Claude Code
keep the tool-schema prefix byte-identical turn-to-turn? That is now answered
**automatically** by `prefix_stable_vs_prev` (no manual prefix-diff needed).

### Empirical baseline — run on your M1 (you run; I instrumented)

```bash
# A. Prefix stability across a real multi-turn trajectory (model-free, RAM-safe)
claude-local-probe                 # send turn 1, then turn 2 (and a few more)
#   ^ NEW: each turn now auto-logs prefix_stable_vs_prev. Read it directly:
grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"
claude-local-prefix-diff           # still works; shows the busting bytes if ❌

# B. Live cache-hit on the Ollama leg (forward mode → real model)
#    Start cc_proxy in FORWARD mode and point a launcher at it:
CC_PROXY_MODE=forward CC_PROXY_PORT=11435 \
  CC_PROXY_LOG="${TMPDIR:-/tmp}/cc_fwd" \
  python3 "$CLAUDE_LOCAL_FAST_DIR/proxy/cc_proxy.py" &
ANTHROPIC_BASE_URL=http://127.0.0.1:11435 claude-local -p "Reply with exactly: OK"
#    then a SECOND identical-prefix turn; read the per-turn telemetry:
cat "${TMPDIR:-/tmp}/cc_fwd/summary.log"          # upstream_ms collapse = hit
cat "${TMPDIR:-/tmp}/cc_fwd/turn_002.timing.json" # prefill_seconds if native fields present

# C. Raw prefill/decode tok/s + duration collapse (BENCHMARKS.md method)
#    two /api/chat calls where call 2 strictly EXTENDS call 1's messages.
```

Record the numbers in the **Results template** at the bottom. Until those are
filled in, no further byte-stream changes are made.

---

## Phase 3 — Plan

### Canonical context layout (what this repo owns vs. Claude Code)

```
[ immutable system prefix ][ stable tool/schema block ][ append-only history ][ volatile tail: date / CLAUDE.md / reminders ]
  └─ repo: agent JSON          └─ repo: agent tool list     └─ Claude Code            └─ Claude Code (already at the tail)
```

This repo's levers are the **first two segments** (agent prompt + tool list) plus
the **warm slot**. Claude Code owns history ordering and tail placement, which the
audit confirms are already correct.

### Per-backend cache adapter (honest: one real backend)

- **Ollama (live):** automatic prefix cache. The "adapter" is the existing tuning
  env (`OLLAMA_FLASH_ATTENTION`, `OLLAMA_KV_CACHE_TYPE=q8_0`) + **warm slot**
  (`OLLAMA_KEEP_ALIVE`). No breakpoint to place. `cc_proxy.py` telemetry is
  backend-agnostic (parses native *or* Anthropic-compat fields).
- **Anthropic cloud (future cascade leg):** if/when a confidence-gated cascade is
  built, its adapter places one `cache_control` breakpoint **after the largest
  stable region**, respecting the per-model minimum-token floor and TTL from
  [KV_CACHE_GROUNDING.md](KV_CACHE_GROUNDING.md) §2. **Not built now** — documented
  as the seam only.

### Compaction policy

This repo does **not** compact; Claude Code owns history/compaction. Policy:
**defer to Claude Code; do not add repo-side compaction.** If a future increment
ever does, it must trigger at a stable boundary (not every turn), be amortized, and
log its one-time re-prefill cost. (N/A today, documented so it isn't done silently.)

### Success criteria (measured vs. the Phase 2 baseline)

1. **Primary (precondition):** `prefix_stable_vs_prev == true` for turns 2..N of a
   representative `claude-local` (medium) trajectory — the tool-schema prefix is
   byte-identical turn-to-turn.
2. **Outcome:** with a warm slot, turn-2+ prefill **duration collapses ≥10×** vs
   turn 1 (ARCHITECTURE.md observed ~40×), confirming reuse on the live leg.
3. **Guardrail:** agent output/behavior **unchanged** — telemetry must not alter the
   forwarded bytes; any future normalizer touches **only** an identified busting
   span at the tail, never reorders/edits history.
4. **Cost framing (honest):** the local leg's marginal **$ is zero** — the real cost
   is **wall-clock prefill seconds per loop**, which is the success metric here. $
   cache savings only apply to the future cascade leg (`cache_read` vs `input`).

### Rollback & increments

- **Increment 1 (DONE):** permanent telemetry in `proxy/cc_proxy.py` + smoke
  contract in `tests/smoke.sh`. No launcher/Modelfile/settings change.
- **Increment 2 (DONE — justified by Phase 2):** Phase 2 found a *specific* buster
  (the `cch` nonce), so the **forward-mode normalizer** was built: opt-in
  `CC_PROXY_NORMALIZE=1`, idempotent, rewrites **only** the two billing-header
  nonce spans to a constant, append-only-safe. Default **off** → transparent, so
  rollback is `unset CC_PROXY_NORMALIZE` (or revert `cc_proxy.py`); no launcher
  change yet.
- **Increment 3 (DONE — opt-in, PR #5):** `CLAUDE_LOCAL_FAST_NORMALIZE=1` routes the
  launchers through `cc_proxy.py` forward+normalize (auto-started on port 11436), so
  the win needs no manual proxy. The proxy also gained an SSE **stream-through** fix
  (`read1()`) so interactive token streaming is preserved. Default **off** (reversible;
  `unset` the var). Validated end-to-end (warm `--continue` 33.9 s → 14.4 s,
  prefix_stable no→yes). **Default-on** is a proposed trivial follow-up once burned in.

---

## Phase 4 — Implement (done)

`proxy/cc_proxy.py`:
- **Telemetry:** `prefix_stable_vs_prev` per real `/v1/messages` turn (both modes) —
  the cache-hit precondition, automatic (`turn_NNN.json` + `summary.log`). Forward
  mode also logs per-turn **upstream latency** + defensive prefill/usage parse →
  `turn_NNN.timing.json`.
- **Normalizer (`CC_PROXY_NORMALIZE=1`, default off):** rewrites the per-request
  prefix nonces — `cch=<hex>` and the `cc_version=X.Y.Z.<hex>` build suffix — to a
  constant, applied **once** before both logging and forwarding, so the telemetry
  reflects the fix and Ollama receives byte-stable bytes. Idempotent (the constant
  has no hex, so it can't re-match); if Claude Code changes the header format the
  patterns simply stop matching (`norm=0`) and the stability telemetry flags it.

`tests/smoke.sh`: asserts the stability-telemetry contract **and** that
`CC_PROXY_NORMALIZE=1` collapses the nonce (`norm=2`, `prefix_stable_vs_prev` flips
to `true`). Model-free / CI-safe.

---

## Measured results (2026-06-24)

Hardware: this 8 GB M1. Claude Code 2.1.170. Ollama tuned env
(`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `KEEP_ALIVE=5m`).

### Phase 2 — baseline / the buster (model-free probe)

Both the **full** (`qwen3-local`, 29 tools, ~93 KB front) and **medium**
(`qwen3-cc`, 7 tools, `tool_bytes=8929`) profiles fail the precondition: the static
prefix is *not* byte-stable turn-to-turn. Same length, different `front_sha`, in **2
spans at offset ~74–106 of the system prompt**:

```
anthropic-billing-header: cc_version=2.1.170.<hex>; cc_entrypoint=sdk-cli; cch=<hex>;
                                              ^^^^^                            ^^^^^
                                      per-process suffix             per-REQUEST nonce
```

`--continue` (same session) isolates it: `cc_version` suffix stays constant,
**`cch` changes every request** (e.g. `3798c → 32a3c`). So `prefix_stable_vs_prev =
false` every turn, even within one agentic loop, on the fast default. This is the
exact "a nonce changes an early token" buster ARCHITECTURE.md warned about — now
named.

### Phase 5 — after the normalizer (real model, qwen3-cc, medium)

Model-free precondition (probe + `CC_PROXY_NORMALIZE=1`): `prefix_stable_vs_prev`
flips **`no → yes`**, both fronts identical (`norm=2`/turn).

Real-model A/B (`/v1/messages` wall-clock, `max_tokens=1`, warm model):

| condition | turn 1 | turn 2 | turn→turn |
|---|---|---|---|
| Control (`cch` varies — Claude Code today) | 30.3 s | 27.5 s | **1.10× (no collapse)** |
| Treatment (`cch` normalized) | 27.6 s | **0.4 s** | **78.5× collapse** |

**Turn-2 prefill 27.5 s → 0.4 s ≈ 78× faster.**

| success criterion | result |
|---|---|
| (1) prefix stable turns 2..N (normalized) | ✅ `prefix_stable_vs_prev=true`, identical `front_sha` |
| (2) prefill collapse ≥10× | ✅ ~78× (beats the ~40× target) |
| (3) output unchanged | ✅ only the billing header (which Ollama ignores) is rewritten; system instructions, tools, and messages are byte-for-byte untouched |

### Reproduce

```bash
# precondition (model-free): no -> yes
claude-local-probe                              # 2 turns, Ctrl-C
grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"     # expect prefix_stable=no
# then run the same 2 turns through forward+normalize and re-check (expect yes):
CC_PROXY_MODE=forward CC_PROXY_NORMALIZE=1 python3 proxy/cc_proxy.py &  # → :11435
# point a launcher's ANTHROPIC_BASE_URL at :11435, send 2 turns, read summary.log
```

> Caveat: the A/B replays one captured medium request directly to Ollama (to avoid
> Claude Code's tool-loop noise and any tool execution); it faithfully reproduces the
> bytes the proxy forwards. The win requires the warm slot (`OLLAMA_KEEP_ALIVE`) to
> still hold the prefix — see Increment 3 for making it automatic.
