# Grounding note: KV-cache / prompt-cache mechanics per backend

**Scope (decided):** this repo routes to exactly **one real backend — local Ollama**
(`qwen3-cc` / `qwen3-local` / `qwen3-air`) — and deliberately leaves cloud `claude`
untouched. So this note covers only what is actually in play: **Ollama prefix-KV
reuse**, the **Anthropic prompt-cache knob** (relevant only to a *future* cascade
escalation leg), and **MLX** (already evaluated and rejected). Every provider in the
generic task prompt that this repo never routes to is listed under §4 as N/A, by
design — not as an omission.

Sources are cited inline. Anything I could not verify against a primary source this
session is **flagged** rather than asserted.

---

## 1. Ollama — automatic prefix-KV reuse (the load-bearing backend)

Claude Code talks to Ollama's native **Anthropic-compatible** Messages API
(`/v1/messages` on `:11434`), so there is **no cache-breakpoint knob** — prefix
caching is **automatic**. Ollama's per-slot KV cache reuses the **longest
token-exact prefix from token 0** and only re-prefills tokens after the first
divergence (already documented in [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)).

| Property | Value |
|---|---|
| How reuse is requested | Automatic. No `cache_control`, no breakpoints. |
| Cache key | Longest **token-exact prefix from position 0**. One differing early byte → re-prefill from there. |
| Minimum cacheable size | None — any prefix is reuse-eligible. |
| "TTL" / eviction | The KV slot survives until the **model unloads** (`OLLAMA_KEEP_ALIVE` expiry, default `5m` here) or a context shift overwrites it. Keeping the slot warm is the lever. |
| Breakpoints allowed | N/A (automatic). |
| Cache hit vs miss | **Hit = `prompt_eval_duration` collapses** turn-to-turn (~40× here: 20.1s→0.5s) while `prompt_eval_count` stays ~full. |
| Tuning that matters | `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_KEEP_ALIVE` (warm slot), `num_gpu 99` (stay 100% GPU). |

**Cache-hit telemetry — exact field names:**

- **Native `/api/chat` / `/api/generate`** (used by the manual benchmark in
  [docs/BENCHMARKS.md](../docs/BENCHMARKS.md)): `prompt_eval_count`,
  `prompt_eval_duration` (**nanoseconds**), `eval_count`, `eval_duration`
  ([ollama/ollama `docs/api.md`](https://github.com/ollama/ollama/blob/main/docs/api.md)).
- **Watch the DURATION, not the count.** On a cache hit `prompt_eval_count` can
  **drop out of the response entirely** while `prompt_eval_duration` and the rest
  remain — verified at
  [ollama/ollama#2068](https://github.com/ollama/ollama/issues/2068). The repo's
  own benchmark note ("watch the duration, not the count") is therefore correct.
  `cc_proxy.py` telemetry keys on duration accordingly.
- **Anthropic-compat `/v1/messages`** (the path Claude Code actually uses): the
  reply carries `usage.{input_tokens,output_tokens}` only — **no prefill timing
  and no cached-token count**. This is why the cache-hit *outcome* on the live
  path is measured as **upstream wall-clock latency collapse**, not a reported
  cached-token field. (Implemented in `cc_proxy.py` forward mode.)

---

## 2. Anthropic prompt caching — the (future) cascade-escalation leg only

This repo's cloud path is plain `claude` (Claude Code, untouched). The repo does
**not** set `cache_control`; Claude Code manages caching on that path internally.
This row is therefore **reference material for a future confidence-gated cascade**
(escalate heavy turns to cloud `claude`, per the ARCHITECTURE.md reframe), **not a
knob this repo controls today.**

Verified against the bundled `claude-api` skill (`shared/prompt-caching.md`):

| Property | Value |
|---|---|
| How a breakpoint is declared | `"cache_control": {"type": "ephemeral"}` on a content block (or top-level auto-cache on the last cacheable block). |
| Render / prefix order | `tools` → `system` → `messages`. Any byte change in the prefix invalidates everything after it. |
| Max breakpoints | **4** per request. |
| Min cacheable prefix | **Opus 4.8/4.7/4.6/4.5 + Haiku 4.5 = 4096 tok**; Fable 5 / Sonnet 4.6 / Haiku 3.5/3 = 2048; Sonnet 4.5/4.1/4/3.7 = 1024. Below the floor it silently won't cache (`cache_creation_input_tokens: 0`). |
| TTL | **5-minute default**; **1-hour** via `{"type":"ephemeral","ttl":"1h"}`. |
| Pricing | Write **1.25×** (5m) / **2×** (1h) base input; read **~0.1×**. |
| Hit telemetry — field names | `usage.cache_read_input_tokens` (served from cache), `usage.cache_creation_input_tokens` (written), `usage.input_tokens` (uncached remainder). **Total prompt = sum of the three.** |
| Tool definitions participate? | **Yes** — they render at position 0; adding/removing/reordering a tool busts the entire cache. |
| Images participate? | **Yes** — `cache_control` is allowed on image blocks. |
| Other gotchas | 20-block lookback window; N parallel requests with the same prefix all pay full price (cache readable only after the first response begins streaming); pre-warm with `max_tokens: 0`. |

**Flag:** I have **not** verified how Claude Code itself places `cache_control` on
the cloud leg — that is internal/closed. Treat this row as the spec a deliberately
-built cascade adapter would target, not as observed behavior of today's `claude`.

---

## 3. MLX — evaluated and rejected (not used)

MLX *does* offer prompt/prefix caching (`make_prompt_cache`, `--prompt-cache-file`),
but **prefix reuse is architecturally broken for sliding-window / hybrid models**
(Qwen3 uses sliding-window attention): the rotating KV buffer can't be trimmed to a
common prefix, so the whole cache is recomputed —
[ml-explore/mlx-lm#980](https://github.com/ml-explore/mlx-lm/issues/980) (verified;
the issue cites a ~40K-token context taking ~200s without reuse vs ~5s with it).
Combined with no native bf16 on a plain M1, ~68 GB/s bandwidth, and 8 GB sitting
below MLX-server floors, MLX is **not** a prefill win here. Ollama + the `--agent`
trim is simpler and goes lower. (Matches [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).)

---

## 4. Out of scope for this repo (flagged, not researched in depth)

The generic task prompt lists a multi-provider router (`cc_bridge.py`) and many
hosted/self-hosted backends. **This repo routes to none of them**, so their caching
mechanics are deliberately not load-bearing here:

- **Hosted:** OpenAI, Google, GLM, hosted-Qwen, Kimi, DeepSeek — N/A (no router leg).
- **Self-hosted clusters:** vLLM / SGLang automatic prefix caching, LMCache KV
  offload, Mooncake-style PD disaggregation — N/A. These target multi-node
  disaggregated serving; this is a single 8 GB M1. The principle (KV-cache I/O
  dominates agentic serving; hit rates are high) is the *motivation*, but the
  cluster machinery is explicitly not deployed.
- **DualPath paper (arXiv 2602.21548) + the "~98.7% DeepSeek agentic hit rate"
  figure:** **UNVERIFIED this session** — I did not fetch the arXiv entry, and the
  hit-rate number is repeated from the prompt, not confirmed against a primary
  source. Use as directional motivation only; do not cite as fact.

---

## 5. What `cc_proxy.py` now records (this repo's own telemetry)

| Signal | Where | Meaning |
|---|---|---|
| `prefix_stable_vs_prev` | `turn_NNN.json`, `summary.log` (both modes) | The cache-hit **precondition**: is this turn's static prefix (system+tools) byte-identical to the previous `/v1/messages` turn? `true` = reuse-eligible, `false` = busted, `null` = first turn. |
| `upstream_ms` | `turn_NNN.timing.json`, `summary.log` (forward mode) | The cache-hit **outcome proxy**: upstream wall-clock latency. Collapses on a reuse. |
| `prompt_eval_duration` / `prefill_seconds` | `turn_NNN.timing.json` (forward mode, when present) | Authoritative prefill time — only when the backend returns native Ollama fields. |
| `usage_input_tokens` / `usage_output_tokens` | `turn_NNN.timing.json` (forward mode, when present) | From the Anthropic-compat `usage` block. |
