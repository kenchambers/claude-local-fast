# Handoff: why `claude-local` is slow, and what actually fixes it

> The original investigation narrative, scrubbed. Numbers were measured on an
> **8 GB M1** running Claude Code against a local Ollama `qwen3:4b-instruct-2507-q4_K_M`
> on **2026-06-19**. See [BENCHMARKS.md](BENCHMARKS.md) for how to reproduce them.

## The bottleneck is prefill, not generation

Running Claude Code against the local model (`claude-local` → Qwen3-4B q4) is
slow because each turn must **prefill Claude Code's ~15–28k-token system prompt**
at only **~100–124 tok/s** = ~2–3 min/turn. Generation (~20 tok/s) is **not**
the bottleneck. On 8 GB, cold model load (~25–95 s) and swap thrashing add more
when the model isn't resident.

## Settings can't trim it; a custom agent can

Measured prompt sizes (cloud, uncapped):

- full profile = **28,261 tokens**
- settings-trim (plugins / skills / CLAUDE.md / MCP off) = **20,226** — only
  ~28% off, disappointing.
- **minimal custom agent = ~3,345 tokens (~8.5× smaller).**

The dominant mass is Claude Code's **built-in tool schemas + base system prompt**,
which a custom `ANTHROPIC_BASE_URL` **inlines in full** (tool-search deferral is
OFF for non-Anthropic endpoints) and which settings **cannot** trim.
`--allowedTools` does **not** shrink it (permissions only). The real lever is
**`--agent` with a custom prompt + a small `tools` list** — it replaces the base
prompt *and* drops unused tool schemas.

The fix that works: launch via
`claude --agent <minimal-agent> --settings <repo>/claude/settings.local-fast.json --strict-mcp-config`
so the prompt is ~3.3k → **~27 s prefill instead of ~160 s**. All flags are
per-invocation, so cloud `claude` and the `-full` launchers are untouched.

## Tool-schema token costs (custom `--agent`)

| Tool set | Tokens |
|---|---|
| 3 tools (Read/Write/Edit) | 2,666 |
| 6 tools (+ Bash/Grep/Glob) | 3,719 |
| **`Task` alone** | **+4,511** (inlines the agent-type catalog — the single biggest contributor) |
| NotebookEdit | +632 |
| WebSearch | +310 |
| WebFetch | +298 |
| TodoWrite | ~0 |

So **`claude-local-medium`** (10 tools = everything but `Task`) = **4,974 tokens**
— ~80% off full, while keeping web + notebook + todo. Dropping `Task` is most of
the win.

## Prefix KV-cache reuse DOES work

Ollama's per-slot cache reuses the longest **token-exact prefix-from-zero** and
only prefills tokens after the first divergence. Measured **~40×** on turn 2
(20.1 s → 0.5 s; an independent run got 14.7 s → 0.34 s) — and it works under
**both `q8_0` and `f16`** KV, so the old "q8_0 disables caching" hypothesis is
disproven.

The earlier "no reuse" conclusion was a measurement bug: it watched
`prompt_eval_count` (which reports the full length even on a cache hit — the real
signal is `prompt_eval_duration`) and changed the *suffix* (a branch, not an
extension). The cache busts only when something changes near the **front** of the
prompt. Claude Code puts its per-turn dynamic content (date, CLAUDE.md,
`<system-reminder>`) in the **messages array, after** the tool block, so the
~28k tool prefix is reuse-eligible *in principle*. It busts only if the date
rolls over, a nonce / non-deterministic schema serialization changes early
tokens, or the model unloads (`OLLAMA_KEEP_ALIVE`).

**To measure prefix stability:** `claude-local-probe` then
`claude-local-prefix-diff` (a model-free probe via `proxy/cc_proxy.py`). If the
prefix is stable, raising `OLLAMA_KEEP_ALIVE` makes turns 2+ near-instant.

## Verified dead ends

- **MLX is not a prefill win on a plain M1**: no native bf16, ~68 GB/s
  bandwidth; the 2.7–4× MLX speedups are M5-specific; prefix-cache reuse is
  architecturally broken for Qwen3's sliding-window attention (mlx-lm #980); and
  8 GB is below MLX servers' 16 GB floor.
- `CLAUDE_CODE_ATTRIBUTION_HEADER` — a header isn't a prompt token.
- Lowering `num_ctx` **for speed** — only helps RAM, not prefill.
- A smaller model — generation was never the bottleneck.
- Don't pin `OLLAMA_KEEP_ALIVE=-1` on 8 GB — it re-creates the RAM-crash risk.

## Best reframe

A confidence-gated **cascade** (inspired by arXiv:2509.07928): route easy /
offline turns to local (the medium agent), and escalate heavy turns to cloud
`claude`. Local isn't competing with the cloud model — it's covering the turns
that don't need it.
