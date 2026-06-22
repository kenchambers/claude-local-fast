# Troubleshooting

## `count_tokens` returns 404 / a turn hangs mid-session

Ollama's Anthropic-compat endpoint can 404 on `/v1/messages/count_tokens`
(Ollama #13949). It's non-fatal, but a turn can stall. Recover with:

```bash
claude-ollama-reset    # force-restart Ollama on 127.0.0.1:11434
```

## Model won't fit / fan spins / everything swaps (8 GB)

The model must stay **100% on the GPU**. Check residency:

```bash
ollama ps    # the % should read 100% GPU, not split CPU/GPU
```

If it spills to CPU:

- Prefer `claude-local` (medium) over `claude-local-full`.
- Lower `num_ctx` in the relevant `ollama/Modelfile.*` (12k is already lean for
  `qwen3-cc`), then rebuild: `ollama create <tag> -f ollama/Modelfile.<tag>`.
- Quit other big RAM users (Chrome, Docker) before a session.
- Never set `OLLAMA_KEEP_ALIVE=-1` globally on 8 GB — it pins the model resident
  and re-creates the out-of-memory crash risk.

## `claude` not found after install

Claude Code is an npm global. If `command -v claude` is empty, your Node/npm
(usually via `nvm`) isn't on this shell's PATH. Load nvm, confirm node, then
reinstall if needed:

```bash
. "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
node --version
npm install -g @anthropic-ai/claude-code
```

The launchers deliberately do **not** hardcode the `claude` path — they use your
PATH, so `nvm use <version>` selects which Node provides it.

## First turn is slow even on the medium profile

The first turn pays a one-time **cold model load** (~25–95 s) on top of prefill.
That's expected, not a regression. Subsequent turns are much faster, and if the
prompt prefix is stable, turn 2+ prefill is near-instant (see
[ARCHITECTURE.md](ARCHITECTURE.md) on KV reuse). Keep the model warm by leaving
`OLLAMA_KEEP_ALIVE=5m` (the default the launchers set).

## It hangs at connect, especially "offline"

Use `127.0.0.1`, never `localhost`. On macOS `localhost` resolves IPv6-first; if
Ollama is listening on IPv4 only, the first connection stalls until timeout. The
launchers already pin `127.0.0.1` everywhere and map the opus/sonnet/haiku tiers
to the local tag (otherwise background tier calls 404 and look like a hang —
the #1 offline trap).

## The model answers in prose instead of using tools

Symptom: you ask something like *"can you see the repo we are in?"* and the local
model replies *"I don't have access to your repository or file system… give me
the path"* instead of actually calling `Glob`/`Grep`/`Read`/`Bash`.

**This is a prompt problem, not a broken API or template.** Verified on Ollama
0.15.6 with `qwen3-air`: tool-calling works on **both** the native `/api/chat`
endpoint *and* the Anthropic `/v1/messages` endpoint Claude Code uses (both
return a clean tool call for "Read the file ./README.md"), and the base
`qwen3:4b-instruct-2507-q4_K_M` template does render a `.Tools` block. The real
cause is that a small 4B model, given a **vague/conversational** question, answers
literally in prose unless its system prompt *compels* proactive tool use.

Reproduced directly: with the old "Use the tools to…" agent prompt the model
returned `stop_reason: end_turn` and the "no file access" prose; with a prompt
that says *"you ARE inside the user repository… you MUST first call a tool… NEVER
say you lack file access"* the same model returned `stop_reason: tool_use` and ran
`Bash ls -la`.

**The shipped fix:** the `claude-code` / `claude-local-medium` / `claude-air-fast`
agent prompts now require tool use. If you still hit it:

- **Phrase requests as concrete tasks.** "Read `setup.sh` and summarize it" or
  "list the repo" works far better than "can you see my files?" on a 4B model.
- **Lower the temperature** for steadier tool-call JSON: drop `temperature` from
  `0.7` toward `0.2` in the relevant `ollama/Modelfile.*` and rebuild
  (`ollama create <tag> -f ollama/Modelfile.<tag>`).
- **Sanity-check the endpoint yourself** if you suspect Ollama:
  ```bash
  curl -s 127.0.0.1:11434/v1/messages -H 'content-type: application/json' -d '{
    "model":"qwen3-air","max_tokens":128,"stream":false,
    "messages":[{"role":"user","content":"Read the file ./README.md"}],
    "tools":[{"name":"Read","input_schema":{"type":"object",
      "properties":{"file_path":{"type":"string"}},"required":["file_path"]}}]}' \
    | python3 -m json.tool
  ```
  A `"type":"tool_use"` block means the stack is healthy and the fix is purely in
  the prompt. If it is missing, then upgrade Ollama (`brew upgrade ollama`,
  `claude-ollama-reset`) and confirm `ollama show <tag> --template` includes a
  `.Tools` section.

## `/doctor` reports a settings issue

`claude/settings.local-fast.json` is intentionally minimal. If `/doctor` flags a
key, it's most likely an unknown/deprecated field for your Claude Code version —
it does not block local runs. Check your version against the one pinned in the
README and prune any key `/doctor` names.
