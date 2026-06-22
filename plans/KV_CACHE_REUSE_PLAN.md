# Plan: maximize KV-cache reuse across `claude-local-fast`'s agentic loops

**Status:** Phase 1 (grounding) and the smallest reversible increment of Phase 4
(permanent telemetry) are **done**. Phases 2/5 (baseline + before/after) are
**run-on-your-M1** steps with a results template below. Further code is **gated on
those measurements** — we do not change the byte stream until a measured prefix
buster justifies it.

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

### Rollback & smallest reversible first increment

- **Increment 1 (DONE):** permanent telemetry in `proxy/cc_proxy.py` + a smoke-test
  contract in `tests/smoke.sh`. **No launcher / Modelfile / settings change.**
  Rollback = revert those two files; nothing else is affected.
- **Next increments (GATED on Phase 2 numbers):**
  - If the prefix is already stable (expected): **no code change** — just raise
    `OLLAMA_KEEP_ALIVE` so warm reuse is automatic, and fold the baseline numbers
    into `docs/BENCHMARKS.md`.
  - If the probe reveals a *specific* buster (a nonce/date/non-deterministic schema
    in the prefix): add a **forward-mode normalizer** in `cc_proxy.py` that rewrites
    **only** the busting bytes (the proxy docstring's long-promised "normalize"),
    behind a flag, idempotent and append-only-safe; then re-measure.

---

## Phase 4 — Implement (increment 1, done)

`proxy/cc_proxy.py`:
- `prefix_stable_vs_prev` per real `/v1/messages` turn (both modes) — the cache-hit
  precondition, automatic and permanent (`turn_NNN.json` + `summary.log`).
- Forward mode: per-turn **upstream latency** + defensive parse of prefill/usage
  fields → `turn_NNN.timing.json` (`prefill_seconds` from ns when native fields are
  present; `usage_*` from the Anthropic-compat shape).

`tests/smoke.sh`: asserts the stability-telemetry contract (turn 1 = `null`, turn 2
compares to turn 1) so it can't silently regress. Stays model-free / CI-safe.

---

## Phase 5 — Validate (you run; report before/after)

Re-run the Phase 2 commands after any gated change and fill the template. If the
uplift doesn't materialize, **do not rationalize it** — read `summary.log`, find the
turn where `prefix_stable_vs_prev` flips to `false`, and diff `turn_NNN.front.txt`
against the prior turn to locate the busting bytes.

### Results template (fill on your M1)

```
Backend / profile: qwen3-cc / claude-local (medium)
Date:
Claude Code version:        ollama --version:

Baseline (Phase 2)
  num_tools / tool_bytes:            ___ / ___
  input_tokens (medium vs full):     ___ / ___
  prefill tok/s (turn 1):            ___
  prefill DURATION turn 1 → turn 2:  ___ s → ___ s   (collapse factor: ___×)
  prefix_stable_vs_prev (turns 2..N):  ___   (yes/no per turn)

After (Phase 5, post-gated-change if any)
  prefill DURATION turn 1 → turn 2:  ___ s → ___ s   (collapse factor: ___×)
  prefix_stable_vs_prev (turns 2..N):  ___
  behavior/output unchanged?           yes / no

Verdict vs success criteria:
  (1) prefix stable turns 2..N?  ___
  (2) duration collapse ≥10×?    ___
  (3) output unchanged?          ___
```
