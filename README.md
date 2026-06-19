# claude-local-fast

Fast local **Claude Code** on Apple Silicon via **Ollama** — make `claude-local` usable on an 8 GB Mac.

Running Claude Code against a local Ollama model is slow because a custom `ANTHROPIC_BASE_URL` makes Claude Code inline **all** built-in tool schemas — a ~28k-token system prompt that must be **prefilled every turn** at ~100–124 tok/s (~3–4 min). This project ships drop-in shell launchers that run Claude Code as a minimal custom `--agent`, cutting the prompt 5–10× (~20 s/turn), plus 8 GB-tuned Ollama Modelfiles and a model-free prefix-stability probe.

| Profile | Tools | ≈ prompt tokens | Simple-message latency |
|---|---|---|---|
| full (stock local) | 29 | ~25k | ~3–4 min |
| `claude-local` (medium) | ~10 | ~2.7k | **~20 s** |
| `claude-code` (minimal) | 6 | ~3k | fastest |

> 🚧 **Under construction.** This repo is being built out from [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md), which contains the complete spec: setup script, shell installer, tuned Modelfiles, proxy/probe, docs, tests, and CI.

## Quick start (target)

```bash
git clone https://github.com/kenchambers/claude-local-fast
cd claude-local-fast
./setup.sh
source ~/.zshrc
claude-local --help
```

## Requirements (target)

macOS on Apple Silicon · ≥ 8 GB RAM · [Ollama](https://ollama.com) · Node 18+ · [Claude Code](https://docs.claude.com/claude-code) · python3

## License

MIT
