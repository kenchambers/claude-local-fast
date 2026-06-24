# Architecture

How `claude-local-fast` makes Claude Code usable against a local model on an
8 GB Apple-Silicon Mac.

## Prefill vs. decode

A transformer turn has two phases:

- **Prefill** — process every token already in the prompt to build the KV
  cache. Compute-bound; on an 8 GB M1 the local model prefills at **~100–124
  tok/s**.
- **Decode (generation)** — emit new tokens one at a time. Memory-bandwidth
  bound; here **~20 tok/s**.

For a normal chat the prompt is small and decode dominates. For Claude Code
against a local endpoint the **prompt is huge and prefill dominates**: a
~28k-token system prompt at ~120 tok/s is **~2–4 minutes before the first
generated token** — every turn.

## Why a custom base URL inlines every tool schema

Against Anthropic's own endpoint, Claude Code can **defer** built-in tool
schemas: the model sees a small `ToolSearch` shim and pulls schemas on demand,
so the static prompt stays small.

Point `ANTHROPIC_BASE_URL` at a local server (Ollama) and that deferral turns
**off** — Claude Code inlines **all** built-in tool schemas plus its full base
system prompt into every request. That is the ~28k tokens. The cost is almost
entirely **tool schemas + base prompt**, and crucially it is **re-sent every
turn**.

What does *not* help:

- `--settings` (disabling plugins / skills / CLAUDE.md / MCP) — only ~28% off
  (28,261 → 20,226 tokens). It can't touch the built-in tool schemas.
- `--allowedTools` — permissions only; zero effect on prompt size.
- A smaller/faster model — decode was never the bottleneck.
- Lowering `num_ctx` — saves RAM, not prefill time.

## The `--agent` lever

A custom **agent** replaces the base system prompt with a tiny one **and**
restricts the tool list, so only those tools' schemas are inlined. That is the
real lever:

| Profile | Tools | ≈ prompt tokens |
|---|---|---|
| full (stock local) | 29 | ~28,261 |
| `claude-local` / medium | 10 (no `Task`) | ~4,974 |
| `claude-code` / minimal | 6 | ~3,345 |

All trimming is **per-invocation** (`--agent` + `--settings` +
`--strict-mcp-config`), so plain `claude`, `claude-local-full`, and
`claude-air-full` are unaffected.

### The `Task` tool is the single biggest line item

`Task` alone is **+4,511 tokens** because its schema inlines the whole
agent-type catalog. Dropping just `Task` is most of the win — which is why the
medium profile keeps everything else (web, notebook, todo) and only sheds
`Task`. Per-tool costs: 3 tools = 2,666; 6 tools = 3,719; NotebookEdit +632;
WebSearch +310; WebFetch +298; TodoWrite ~0.

## Ollama prefix KV-cache reuse

Ollama's per-slot KV cache reuses the **longest token-exact prefix from token
zero** and only prefills tokens after the first divergence. When the front of
the prompt is byte-stable turn-to-turn, **turn 2 prefill collapses ~40×**
(measured 20.1 s → 0.5 s; an independent run 14.7 s → 0.34 s), under **both**
`q8_0` and `f16` KV cache.

Claude Code places its per-turn dynamic content (the date, CLAUDE.md,
`<system-reminder>` blocks) in the **messages array — after** the tool block, so
the big tool-schema prefix is reuse-eligible *in principle*. It busts only if:

- the date rolls over or a nonce changes an early token,
- schema serialization is non-deterministic across turns, or
- the model unloads between turns (`OLLAMA_KEEP_ALIVE` expiry).

**Measured (Claude Code 2.1.170):** the first of those *does* happen. Claude Code
injects an `anthropic-billing-header` at the front of the system prompt —
`cc_version=2.1.170.<hex>; cc_entrypoint=sdk-cli; cch=<hex>` — whose **`cch` is a
per-request nonce that changes every turn** (even within one `--continue` session),
on both the full and the fast medium profiles. At ~74 bytes in, it busts reuse
every turn. The opt-in proxy normalizer (`CC_PROXY_NORMALIZE=1`) rewrites it to a
constant — Ollama ignores billing headers — restoring reuse: measured **27.5 s →
0.4 s (~78×)** turn-2 prefill on the medium profile. See
[BENCHMARKS.md](BENCHMARKS.md) and [../plans/KV_CACHE_REUSE_PLAN.md](../plans/KV_CACHE_REUSE_PLAN.md).

Measure stability yourself with the model-free probe (`proxy/cc_proxy.py`):
`claude-local-probe` captures two real turns and now auto-logs `prefix_stable_vs_prev`
per turn; `claude-local-prefix-diff` reports ✅ identical or ❌ with the exact
busting bytes. If stable, raising `OLLAMA_KEEP_ALIVE` keeps the slot warm and
turns 2+ are near-instant.

## Why MLX loses on M1

MLX is tempting but **not** a prefill win on a plain M1: no native bf16,
~68 GB/s memory bandwidth (the headline 2.7–4× MLX speedups are M5-specific),
prefix-cache reuse is architecturally broken for Qwen3's sliding-window
attention (mlx-lm #980), and 8 GB is below MLX servers' ~16 GB floor. Ollama +
the `--agent` trim is simpler and goes lower.

## The reframe: a confidence-gated cascade

Local isn't competing with the cloud model head-to-head. The durable framing
(inspired by **arXiv:2509.07928**) is a **cascade**: handle easy and offline
turns locally with the medium agent, and escalate heavy turns to cloud `claude`.
`claude-local-fast` ships the fast local half of that cascade.

## Tuning for 8 GB

The Modelfiles and the `_ollama_serve_tuned` env keep the model **100%
GPU-resident** so it never spills to CPU:

- `num_ctx` 12k (cc) / 16k (local, air) — a 64k KV cache (~4.6 GB) + 2.5 GB
  weights overcommits the ~5.3 GB usable on 8 GB and spills to CPU.
- `num_gpu 99` — full Metal offload; the 2.5 GB q4 weights fit in unified memory.
- `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` — half-size KV cache,
  ~no quality loss.
- `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1` — never co-resident a
  second model on 8 GB.
- `repeat_penalty 1.0` — Ollama's 1.1 default corrupts Qwen's code/JSON tokens.

Verify residency: `ollama ps` should show **100% GPU**.
