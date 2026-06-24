# claude-local-fast

[![ci](https://github.com/kenchambers/claude-local-fast/actions/workflows/ci.yml/badge.svg)](https://github.com/kenchambers/claude-local-fast/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Fast local **Claude Code** on Apple Silicon via **Ollama** — make `claude-local`
usable on an 8 GB Mac.

Running Claude Code against a local Ollama model is slow because a custom
`ANTHROPIC_BASE_URL` makes Claude Code inline **all** built-in tool schemas — a
~28k-token system prompt that must be **prefilled every turn** at ~100–124 tok/s
(~3–4 min/turn). Generation (~20 tok/s) isn't the bottleneck; **prefill is.**
This repo ships drop-in shell launchers that run Claude Code as a **minimal
custom `--agent`**, cutting the prompt 5–10× (~20–40 s/turn), plus 8 GB-tuned
Ollama Modelfiles and a model-free prefix-stability probe.

| Profile | Tools | ≈ prompt tokens | Simple-message latency |
|---|---|---|---|
| full (stock local) | 29 | ~28k | ~3–4 min |
| `claude-local` (medium) | 10 (no `Task`) | ~5k | **~20–40 s** |
| `claude-code` (minimal) | 6 | ~3k | fastest |

The `Task` tool alone is **+4,511 tokens** (it inlines the agent-type catalog) —
dropping it is most of the win. Full details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Quick start

```bash
git clone https://github.com/kenchambers/claude-local-fast
cd claude-local-fast
./setup.sh            # installs deps, builds the tuned models, wires your shell
source ~/.zshrc
claude-local --help
```

`setup.sh` is idempotent. Flags: `--yes` (non-interactive), `--no-shell`,
`--shell zsh|bash`, `--dir <path>`, `--skip-models`.

## Command reference

| Command | What it is | Prompt | Speed |
|---|---|---|---|
| `claude-local` | → `claude-local-medium` (fast default) | ~5k tok | ~40 s cold, near-instant warm |
| `claude-local-full` | full profile, ALL tools (incl. `Task`) | ~28k tok | ~2 min first turn |
| `claude-code` | minimal 6-tool agent (Read/Write/Edit/Bash/Grep/Glob) | ~3k tok | fastest |
| `claude-air` | → `claude-air-fast` (8 tools, offline, no web; **KV-reuse on**) | ~4k tok | fast, offline |
| `claude-air-full` | airplane, ALL tools incl. `Task` (offline; **KV-reuse on**) | ~28k tok | slow first turn |
| `claude` | cloud Anthropic (untouched) | — | cloud |

Diagnostics & recovery:

| Command | What it does |
|---|---|
| `claude-local-medium` | the 10-tool agent `claude-local` actually runs |
| `claude-local-probe` | capture the REAL full prompt, model-free (RAM-safe) |
| `claude-local-prefix-diff` | diff two probed turns → will Ollama KV-reuse engage? |
| `claude-local-probe-stop` | stop the probe proxy |
| `claude-ollama-reset` | force-restart Ollama if it hangs mid-session |
| `claude-local-stop` | stop Ollama now — unload models + kill the daemon to free RAM |

All trimming is **per-invocation**, so plain `claude` keeps using cloud Anthropic
and your existing routing untouched.

### KV-cache reuse (the `cch` nonce fix)

Claude Code injects a per-request `cch` nonce in an `anthropic-billing-header` at
the **front** of the system prompt, which busts Ollama's prefix-KV cache on *every*
turn. A small localhost proxy (`proxy/cc_proxy.py`, forward+normalize) rewrites that
nonce to a constant so the prefix is byte-stable and Ollama reuses it — **~20 s saved
per warm turn** on medium (prefill-only collapse ~78×).

- **`claude-air` / `claude-air-full` → ON by default.** In flight, prefill is pure
  battery-burning compute and the proxy is localhost-only (offline-safe), so reuse is
  a free win. Falls back to direct Ollama if `python3` is missing.
- **`claude-local` / `-medium` / `-full` / `claude-code` → opt-in:** `export CLAUDE_LOCAL_FAST_NORMALIZE=1`
- **Force off anywhere** (including airplane): `CLAUDE_LOCAL_FAST_NORMALIZE=0`

Watch it engage: `grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"` (expect
`prefix_stable=yes` from turn 2 on).

✈️ **Flying?** The full pre-flight → in-flight → verify → recover runbook is in
**[docs/AIRPLANE_MODE.md](docs/AIRPLANE_MODE.md)**.

### RAM hygiene (auto-stop Ollama)

`OLLAMA_KEEP_ALIVE=5m` only unloads the **model** after it goes idle; the
`ollama serve` daemon — and any model pinned by the airplane launchers
(`keep_alive:-1`) — stays resident until reboot. So **the shell that started
Ollama also stops it on exit**: it unloads every model (frees the ~4 GB) and kills
the daemon. Only that owner shell does this, so a daemon started by Ollama.app or
`brew services` is left alone. Free it sooner with `claude-local-stop`, or keep it
resident across shell exits by exporting `CLAUDE_LOCAL_FAST_NO_AUTOSTOP=1`.

## Requirements

- macOS on **Apple Silicon** (8 GB supported, 16 GB comfortable)
- [Ollama](https://ollama.com)
- Node 18+ and npm (via [nvm](https://github.com/nvm-sh/nvm) recommended)
- [Claude Code](https://docs.claude.com/claude-code) — tested with **v2.1.x**
- python3 (stdlib only; for the probe)

> **Version coupling:** Claude Code resolves tool-deferral behavior on custom
> endpoints from a remote flag, and Ollama's Anthropic-compat tool handling is
> evolving — both can shift across releases. Keep Ollama and Claude Code current
> if behavior changes; see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## How it works

A custom `ANTHROPIC_BASE_URL` turns off Claude Code's tool-schema deferral, so it
inlines every built-in tool schema into a ~28k-token prompt that re-prefills each
turn. Launching as a minimal custom `--agent` swaps the huge base prompt for a
tiny one and drops unused tool schemas; Ollama's prefix KV cache then reuses the
stable front of the prompt (~40× faster prefill on turn 2). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/HANDOFF.md](docs/HANDOFF.md).

## Benchmarks

Measured on an 8 GB M1 — numbers and exact reproduction commands in
[docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Troubleshooting

Common issues (count_tokens 404, swap thrash on 8 GB, `claude` not on PATH, cold
first turn, the `127.0.0.1` vs `localhost` IPv6 gotcha, the local model answering
instead of calling tools) are covered in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Uninstall

```bash
./uninstall.sh                 # remove the managed block from your rc
./uninstall.sh --purge-models  # also drop the 3 tuned tags (keeps the base model)
```

Homebrew, Node, Ollama, and Claude Code are left untouched.

## Credits

- [Ollama](https://ollama.com) and the [Qwen3](https://github.com/QwenLM/Qwen3)
  team (Qwen3-4B-Instruct-2507).
- [Anthropic Claude Code](https://docs.claude.com/claude-code).
- Cascade framing: [arXiv:2509.07928](https://arxiv.org/abs/2509.07928);
  on-device LLM survey: [arXiv:2503.06027](https://arxiv.org/abs/2503.06027).

## License

[MIT](LICENSE)
