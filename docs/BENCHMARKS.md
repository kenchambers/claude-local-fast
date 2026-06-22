# Benchmarks

All numbers measured on an **8 GB M1**, Claude Code against a local Ollama
`qwen3:4b-instruct-2507-q4_K_M`, **2026-06-19**. Your mileage varies with RAM,
thermal state, and Claude Code / Ollama versions — treat these as the shape of
the win, not guarantees. CI does **not** run these (they need Apple-Silicon
hardware); the commands below reproduce them locally.

## Prompt size by profile

| Profile | Tools | Tool-schema bytes | ≈ prompt tokens | Simple-message latency |
|---|---|---|---|---|
| full (stock local) | 29 | 82,872 | ~28,261 | ~3–4 min |
| settings-trim only | 29 | — | ~20,226 | ~2–3 min |
| `claude-local` (medium) | 10 (no `Task`) | 8,929 | ~4,974 | **~20–40 s** |
| `claude-code` (minimal) | 6 | — | ~3,345 | fastest |

Settings-trimming alone (plugins / skills / CLAUDE.md / MCP off) is only ~28%
off — the built-in **tool schemas** dominate and only `--agent` sheds them.

## Per-tool schema cost (custom `--agent`)

| Tool set | Tokens |
|---|---|
| 3 tools (Read/Write/Edit) | 2,666 |
| 6 tools (+ Bash/Grep/Glob) | 3,719 |
| **`Task`** | **+4,511** |
| NotebookEdit | +632 |
| WebSearch | +310 |
| WebFetch | +298 |
| TodoWrite | ~0 |

`Task` inlines the agent-type catalog and is the single biggest contributor —
which is why the medium profile keeps everything *except* `Task`.

## Speed phases

- **Prefill:** ~100–124 tok/s (the bottleneck).
- **Decode:** ~20 tok/s (not the bottleneck).
- **Cold model load:** ~25–95 s the first time the model is touched.
- **Prefix KV reuse, turn 2:** ~**40×** faster prefill (20.1 s → 0.5 s; an
  independent run 14.7 s → 0.34 s) when the prompt prefix is byte-stable, under
  both `q8_0` and `f16` KV.

---

## Reproduce it

### 1. Prompt size, model-free (the probe)

```bash
claude-local-probe          # starts cc_proxy in probe mode (no model loaded)
# type a short prompt + Enter, then a SECOND prompt + Enter, then Ctrl-C
claude-local-prefix-diff    # prints num_tools / tool_bytes and ✅/❌ prefix stability
```

Read `${TMPDIR:-/tmp}/cc_proxy/turn_001.json` for `num_tools` and `tool_bytes`
of the **full** profile. To size a trimmed profile, point a launcher's flags at
the proxy port (`ANTHROPIC_BASE_URL=http://127.0.0.1:11435`) the same way the
probe does.

### 2. Prefill / decode tok/s

```bash
curl -s 127.0.0.1:11434/api/chat -d '{
  "model":"qwen3-cc","stream":false,
  "messages":[{"role":"user","content":"Reply with exactly: OK"}],
  "options":{"num_predict":16}
}' | python3 -m json.tool | grep -E 'eval_count|eval_duration'
```

- prefill tok/s = `prompt_eval_count / (prompt_eval_duration / 1e9)`
- decode tok/s  = `eval_count / (eval_duration / 1e9)`

### 3. Prefix KV reuse

Make two `/api/chat` calls where call 2's `messages` strictly **extend** call 1's
(append, don't branch). Reuse shows as `prompt_eval_duration` collapsing
(~20 s → ~0.3–0.5 s) while `prompt_eval_count` stays at the full length (it
reports total prompt length even on a cache hit — watch the **duration**, not the
count).

### 4. End-to-end turn latency

```bash
claude-local -p "Reply with exactly: OK" --output-format json
# inspect usage.input_tokens (~2.7–5k for medium) and wall-clock time
claude-local-full -p "Reply with exactly: OK" --output-format json
# contrast: ~25k+ input_tokens, minutes of prefill
```
