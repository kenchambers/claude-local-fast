# Session handoff — KV-cache reuse for `claude-local-fast`

**Purpose:** hand this to a fresh session so it can continue *exactly* where we left
off. Read this top-to-bottom, then jump to **§9 Next step**.

Last updated: 2026-06-24.

---

## 1. One-paragraph state

We set out to "maximize KV-cache reuse across the agentic loop." We added permanent
prefix-stability **telemetry** to the proxy, used it to **discover** that Claude Code
2.1.170 injects a per-request nonce (`cch`) at the front of the system prompt that
**busts Ollama prefix-KV reuse on every turn** — including on the fast `claude-local`
(medium) default — and shipped an opt-in **normalizer** that rewrites that nonce to a
constant, **measured to collapse turn-2 prefill 27.5 s → 0.4 s (~78×)** on qwen3-cc.
PRs: #2 merged; #3 + #4 + #5 open. **Increment 3 is done** — the end-to-end gains
check passed (controlled real-model A/B: warm `--continue` turn **33.9 s → 14.4 s**,
`prefix_stable` no→yes), so the launchers now route through the normalizer behind an
opt-in flag (`CLAUDE_LOCAL_FAST_NORMALIZE=1`) and the proxy streams SSE through.

## 2. Scope reconciliation (important)

The original task prompt was written for a generic multi-provider router
(`cc_bridge.py`, MT5, OpenAI/Google/DeepSeek/vLLM…). **None of that exists in this
repo.** `claude-local-fast` is the *fast local half*: **one real backend = local
Ollama** (`qwen3-cc`/`-local`/`-air` via the `--agent` trim) + an **untouched cloud
`claude`**. So "maximize KV-cache reuse" here = **Ollama prefix-KV reuse**. The
Anthropic prompt-cache knob is reference-only for a *future* cascade leg; MLX is
rejected. Full backend mechanics: `plans/KV_CACHE_GROUNDING.md`.

## 3. The key finding (the buster)

Claude Code injects this at the **front** of the system prompt (offset ~74 B):

```
anthropic-billing-header: cc_version=2.1.170.<hex>; cc_entrypoint=sdk-cli; cch=<hex>;
                                              ^^^^^                            ^^^^^
                                  per-PROCESS build suffix            per-REQUEST nonce
```

- `cch=<hex>` **changes every request** — proven with `--continue` (same session):
  `cc_version` suffix stays constant, `cch` goes e.g. `3798c → 32a3c`.
- It busts **both** the full (`qwen3-local`, 29 tools, ~93 KB front) and the fast
  **medium** (`qwen3-cc`, 7 tools, `tool_bytes=8929`) profiles.
- Because it's ~74 B in, it invalidates essentially the whole prefix → Ollama
  re-prefills the full ~5–28k tokens **every turn**. This is the exact "a nonce
  changes an early token" buster ARCHITECTURE.md predicted — now named.
- Likely tied to the `prompt-caching-scope-2026-01-05` beta header (a cache-scope
  hash for Anthropic's *own* caching); **meaningless to Ollama**.

## 4. Measurements (all on this 8 GB M1, Claude Code 2.1.170)

**Model-free (probe):** `prefix_stable_vs_prev=false` turn-to-turn on both profiles
(same front length, different `front_sha`, diff isolated to the 2 billing-header
spans). With `CC_PROXY_NORMALIZE=1` → flips **`no → yes`**, identical `front_sha`,
`norm=2`/turn.

**Real model (qwen3-cc, medium, `/v1/messages` wall-clock, `max_tokens=1`, warm):**

| condition | turn 1 | turn 2 | turn→turn |
|---|---|---|---|
| Control — `cch` varies (Claude Code today) | 30.3 s | 27.5 s | **1.10× (no collapse)** |
| Treatment — `cch` normalized | 27.6 s | **0.4 s** | **78.5× collapse** |

The A/B replays one captured medium request to Ollama directly (avoids Claude Code's
tool loop + any tool execution); it faithfully reproduces the bytes the proxy
forwards. In a *real* loop the win is ≥ this, because the slot also caches prior
turns' tokens, so only the newest user message prefills.

## 5. What was built (and where)

| PR | branch | what | state |
|---|---|---|---|
| **#2** | `feat/kv-cache-telemetry` | `prefix_stable_vs_prev` telemetry + forward-mode latency/prefill logging; smoke contract; `plans/KV_CACHE_*.md` | **MERGED** to main |
| **#3** | `feat/ollama-autostop-ram-hygiene` | auto-stop Ollama on owner-shell exit + `claude-local-stop` (pre-existing RAM-hygiene WIP) | **OPEN** |
| **#4** | `feat/kv-cache-normalizer` | the normalizer (`CC_PROXY_NORMALIZE=1`) + normalizer smoke test + measured before/after in BENCHMARKS/ARCHITECTURE/plan | **OPEN** |
| **#5** | `feat/kv-cache-autowire` (stacked on #4) | opt-in `CLAUDE_LOCAL_FAST_NORMALIZE=1` routes launchers through forward+normalize; SSE stream-through fix; this handoff doc | **OPEN** |

Key files:
- `proxy/cc_proxy.py` — telemetry + normalizer. **Stdlib only.**
- `tests/smoke.sh` — model-free CI tests (probe self-test + stability + normalizer).
- `shell/claude-local-fast.zsh` — the launchers (zsh).
- `plans/KV_CACHE_GROUNDING.md`, `plans/KV_CACHE_REUSE_PLAN.md` — grounding + plan + measured results.
- `docs/BENCHMARKS.md`, `docs/ARCHITECTURE.md` — updated with the finding + numbers.

## 6. How the telemetry + normalizer work (`proxy/cc_proxy.py`)

- The proxy sits between Claude Code and Ollama. `CC_PROXY_MODE=probe` (default,
  model-free canned reply) or `forward` (relay to Ollama at `CC_PROXY_UPSTREAM`).
- **Telemetry (both modes):** every real `/v1/messages` turn logs
  `prefix_stable_vs_prev` (is the static system+tools front byte-identical to the
  prior turn?) to `turn_NNN.json` + `summary.log`. Forward mode also logs
  `upstream_ms` (+ defensive prefill/usage parse) to `turn_NNN.timing.json`.
- **Normalizer (`CC_PROXY_NORMALIZE=1`, default OFF → transparent):** in `do_POST`,
  *before* logging+forwarding, regex-rewrites `cch=<hex>` and the
  `cc_version=X.Y.Z.<hex>` suffix to a constant (`_normalize_raw`). Applied once so
  telemetry reflects the fix and Ollama gets byte-stable bytes. Idempotent; if the
  header format changes the patterns stop matching (`norm=0`) and the telemetry
  flags it. Ollama ignores billing headers → instructions/tools/messages unchanged.

## 7. How to reproduce / verify

```bash
# Model-free precondition (no model load, RAM-safe):
claude-local-probe                 # send 2 turns in the SAME session, Ctrl-C
grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"   # expect prefix_stable=no

# Prove the fix model-free: run cc_proxy probe with CC_PROXY_NORMALIZE=1 and
# replay two medium requests differing only in cch -> prefix_stable flips to yes.
bash tests/smoke.sh                # the normalizer self-test does exactly this

# Real-model A/B is in git history of feat/kv-cache-normalizer (replay harness).
```

The driving trick for non-interactive probing: replicate a launcher's env, point
`ANTHROPIC_BASE_URL` at the proxy, run `claude -p "..."` (one turn) then
`claude --continue -p "..."` (same-session turn 2). The proxy logs each request on
receipt, so the verdict is captured even if Claude Code dislikes the canned reply.

## 8. Gotchas / caveats learned

- **Watch DURATION, not count.** Ollama's `prompt_eval_count` can drop out on a cache
  hit (ollama/ollama#2068); the reliable signal is `prompt_eval_duration` collapse.
- Native `/api/chat` exposes `prompt_eval_duration`; the Anthropic-compat
  `/v1/messages` (what Claude Code uses) exposes `usage.{input,output}_tokens` only —
  so the live cache-hit *outcome* is measured as **upstream wall-clock latency**.
- The win needs the **warm slot** (`OLLAMA_KEEP_ALIVE`, set to 5m by the launchers);
  turns must be < keep-alive apart.
- Two *separate* `claude -p` processes = two sessions (cross-session); use
  `--continue` for the real within-session loop behavior.
- `cc_proxy.py` forward mode now **streams SSE through** (PR #5, `read1()` so
  trickled events relay immediately); non-SSE JSON is still buffered with
  Content-Length. `upstream_ttfb_ms` (time-to-first-byte ≈ prefill) is logged too.
- macOS has no `timeout` binary; use Python `subprocess(..., timeout=)` to bound runs.
- On the default branch, branch first; the README/shell RAM-hygiene edits are PR #3.
- **Test-dir pollution:** Claude Code stores conversation history per directory.
  Running many `claude -p`/`--continue` here accumulated a 200+ message conversation,
  so a launcher run showed `msgs=226`/189 s (blew past qwen3-cc's 12k ctx) — a test
  artifact, not the feature. Use `claude -p` (fresh) or a clean dir for clean numbers;
  do NOT delete the user's real conversation history to "fix" it.

## 9. Increment 3 — DONE (PR #5), and what's left

**Built (opt-in):** `export CLAUDE_LOCAL_FAST_NORMALIZE=1` makes every launcher route
through `cc_proxy.py` forward+normalize (auto-started on port 11436; probe stays on
11435) so the cch nonce is stripped and Ollama reuses the prefix. The proxy now
**streams SSE through** (`read1()`), so interactive token streaming is preserved;
non-SSE JSON stays buffered. A `zshexit` hook stops the proxy we started. Validated:
controlled real-model A/B (warm `--continue` 33.9 s → 14.4 s, prefix_stable no→yes),
proxy lifecycle, SSE incremental relay, JSON path intact, `zsh -n`/smoke/shellcheck.

**What's left (proposed):**
1. **Default-on — DONE for AIRPLANE (2026-06-24), still opt-in for online.**
   `claude-air` / `claude-air-full` now route through the reuse proxy **by default**
   (in flight, prefill is pure battery-burning compute and the proxy is localhost-only
   → offline-safe; falls back to direct Ollama if `python3` is missing). The online
   launchers (`claude-local`/`-medium`/`-full`/`claude-code`) stay **opt-in**
   (`CLAUDE_LOCAL_FAST_NORMALIZE=1`) so the proxy keeps burning in as a reliability
   surface there. Mechanism: `_claude_local_normalize_on <default>` predicate — the
   env var, when set, always wins (`0/false/no/off` → off, `1/true/yes/on` → on; this
   also **fixes** the old `-n` test that treated `=0` as on), and the per-launcher
   default (airplane=1, online=0) decides only when the env var is unset/empty.
   Covered by smoke test step 6 (routing truth table). Remaining: flip the online
   launchers to default-on too once burned in (change their `0` arg to `1`).
2. ~~Probe the airplane profile~~ **DONE (2026-06-24).** `claude-air` (qwen3-air,
   offline) carries the same `anthropic-billing-header` `cch` nonce at the front →
   `prefix_stable=no` (e.g. `cch=46dd6` vs `0d022`); with `CC_PROXY_NORMALIZE=1` both
   fronts collapse to an identical `front_sha` (`prefix_stable=yes`, `norm=2`). So the
   buster + fix are confirmed on all three profiles (full / medium / air). Model-free
   probe via the fresh-`claude -p` harness (no `--continue`, so no transcript pollution).
   Note: air's inlined `num_tools=5` (not the 8 listed) — Claude Code doesn't inline a
   schema for every agent tool; cosmetic, unrelated to the buster.
3. **Stale-handoff hygiene** — this doc + the test-dir pollution note (§8).

**Honest gain framing for docs:** headline 78× is prefill-*only* (clean A/B); the
end-to-end per-turn wall-clock gain is ~2.4× / **~20 s saved per warm turn** on
medium (decode cost is unchanged). State both; don't let 78× imply 78× wall-clock.

## 10. Command cheat-sheet

```bash
# branches
git branch --show-current
gh pr list --state open

# run the model-free tests
bash tests/smoke.sh

# start tuned Ollama (matches the launchers)
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=5m OLLAMA_NO_CLOUD=1 \
  ollama serve & ; ollama list

# stop Ollama (free RAM) — the launchers do this on shell exit
ollama stop qwen3-cc; pkill -x ollama; pkill -f "ollama runner"

# forward+normalize proxy (the Increment-3 routing, done manually)
CC_PROXY_MODE=forward CC_PROXY_NORMALIZE=1 CC_PROXY_PORT=11435 python3 proxy/cc_proxy.py &
#   then point a launcher's ANTHROPIC_BASE_URL at http://127.0.0.1:11435
```
