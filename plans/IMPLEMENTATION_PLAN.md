# Implementation Plan: `claude-local-fast`

**Audience:** an autonomous coding agent (or contributor) building this repo out.
**Goal:** package the "fast local Claude Code on Apple Silicon / Ollama" tooling into a clean, public repo with a README, a one-command setup script that installs every dependency, a shell-installer that wires the launchers into the user's shell, full docs, tests, and CI.
**Status:** spec. Execute top-to-bottom.

> This is the public/scrubbed plan. It assumes the build runs on the maintainer's Apple-Silicon machine, where the source artifacts (the proxy script, tuned Modelfiles, the shell launcher block, and the settings file) already exist and are harvested into the repo (see §2). Replace any `<placeholders>` with your own values.

---

## 0. Parameters

| Name | Value |
|---|---|
| `REPO_NAME` | `claude-local-fast` |
| `VISIBILITY` | `public` |
| `GH_OWNER` | your GitHub login (verify with `gh api user -q .login`) |
| `LICENSE` | MIT |
| `DEFAULT_BRANCH` | `main` |
| `BASE_MODEL` | `qwen3:4b-instruct-2507-q4_K_M` |
| `MODEL_TAGS` | `qwen3-cc` (12k ctx), `qwen3-local` (16k), `qwen3-air` (16k battery) |
| `INSTALL_DIR` | the repo clone path, exported as `CLAUDE_LOCAL_FAST_DIR` |
| `PROXY_PORT` | `11435` (probe); Ollama stays on `11434` |

**Because the repo is PUBLIC:** no absolute user paths, no personal names/emails, no references to unrelated local projects. See §5 Scrubbing — this is a hard gate before first push. Commit with a `noreply` git email, not a personal one.

---

## 1. What this tool does (the elevator pitch for the README)

Running Claude Code against a **local** Ollama model on an 8 GB Apple-Silicon Mac is unusably slow (~2–4 min/turn) because a custom `ANTHROPIC_BASE_URL` makes Claude Code **inline all built-in tool schemas** — a ~28k-token system prompt that must be **prefilled every turn at ~100–124 tok/s**. Generation (~20 tok/s) is not the bottleneck; **prefill is**.

This repo ships drop-in shell launchers that cut the prompt 5–10× by running Claude Code as a **minimal custom `--agent`**, plus tuned Ollama Modelfiles sized for 8 GB, a model-free **prefix-stability probe**, and a one-command installer.

**Measured on an 8 GB M1 (document in BENCHMARKS.md):**

| Profile | Tools | Tool-schema bytes | ≈ tokens | Simple-message latency |
|---|---|---|---|---|
| full (stock local) | 29 | 82,872 | ~25k | ~3–4 min |
| `claude-local` (medium) | ~10 | 8,929 | ~2.7k | **~20 s** |
| `claude-code` (minimal) | 6 | — | ~3k | fastest |

Other verified facts to surface in docs:
- The **`Task` tool alone is +4,511 tokens** (it inlines the agent-type catalog) — dropping it is most of the win.
- **Ollama's prefix KV cache DOES reuse** the static prefix (~40× faster prefill on turn 2, under both `q8_0` and `f16` KV) **when the front of the prompt is byte-stable** — the probe measures this.
- **MLX is not a prefill win on M1** (no native bf16; prefix-cache reuse broken for Qwen3 sliding-window attention; 8 GB below MLX-server floors).
- Reframe / future work: a confidence-gated **cascade** (local for easy/offline turns, escalate heavy work to cloud `claude`), inspired by arXiv:2509.07928.

---

## 2. Harvest existing artifacts from the build machine (do this FIRST)

These files already exist on the maintainer's machine and are the source of truth. Copy them into the repo, then parameterize + scrub (§5). Do **not** hand-rewrite from memory.

| Source on build machine | Repo destination | Notes |
|---|---|---|
| `~/.claude/cc_proxy.py` | `proxy/cc_proxy.py` | Stdlib-only; already env-parameterized (probe/forward modes). Copy as-is, verify no personal paths. |
| `~/.claude/settings.local-fast.json` | `claude/settings.local-fast.json` | **Scrub** `claudeMdExcludes` of any personal paths; keep generic toggles. |
| `~/.ollama/Modelfile.qwen3-cc` | `ollama/Modelfile.qwen3-cc` | `num_ctx 12288`, `num_gpu 99`, Qwen sampling (`repeat_penalty 1.0`). |
| `~/.ollama/Modelfile.qwen3-local` | `ollama/Modelfile.qwen3-local` | `num_ctx 16384`. |
| `~/.ollama/Modelfile.qwen3-air` | `ollama/Modelfile.qwen3-air` | battery profile, `num_ctx 16384`. |
| `~/.zshrc` — only the launcher block | `shell/claude-local-fast.zsh` | **Extract ONLY** the `claude-local*`, `claude-air*`, `claude-code`, `claude-ollama-reset`, `claude-local-probe*`, and the three helpers `_ollama_serve_tuned` / `_ensure_ollama_model` / `_claude_local_launch`. Nothing else from the user's rc. |
| `~/.claude/hooks/help-free-ram.sh` | `hooks/help-free-ram.sh` | OPTIONAL component (see §4). |
| the speed-handoff write-up (kept with the maintainer's notes) | `docs/HANDOFF.md` | The "why" narrative; scrub any personal/project references. |

If a source file is missing, generate it from the spec in §4 and flag it in the PR description.

---

## 3. Repo structure

```
claude-local-fast/
├── README.md
├── LICENSE                       # MIT
├── .gitignore
├── setup.sh                      # one-command installer (deps → models → config → shell)
├── uninstall.sh                  # reverses install_shell + optional model removal
├── install/
│   ├── deps.sh                   # detect/install Homebrew, Ollama, Node+npm, Claude Code, python3
│   ├── build_models.sh           # ollama pull BASE_MODEL + ollama create the 3 tuned tags
│   └── install_shell.sh          # idempotent shell-rc injection (THE "add to zshrc" script)
├── shell/
│   └── claude-local-fast.zsh     # all launcher functions + helpers (parameterized, zsh)
├── ollama/
│   ├── Modelfile.qwen3-cc
│   ├── Modelfile.qwen3-local
│   └── Modelfile.qwen3-air
├── claude/
│   └── settings.local-fast.json
├── proxy/
│   └── cc_proxy.py               # model-free probe + transparent forward proxy
├── hooks/
│   └── help-free-ram.sh          # OPTIONAL: 8GB emergency RAM-free hook
├── docs/
│   ├── ARCHITECTURE.md           # prefill bottleneck, agent profiles, KV reuse, why MLX loses
│   ├── BENCHMARKS.md             # the measured numbers + how to reproduce
│   ├── TROUBLESHOOTING.md        # 8GB RAM, count_tokens 404, model won't unload, etc.
│   └── HANDOFF.md                # harvested narrative
├── plans/
│   └── IMPLEMENTATION_PLAN.md    # this file
├── tests/
│   └── smoke.sh                  # zsh -n, py_compile, json validate, probe self-test
└── .github/
    └── workflows/ci.yml          # shellcheck + py_compile + json/zsh lint + smoke
```

---

## 4. File-by-file specification

### `shell/claude-local-fast.zsh` (the core)
Parameterized extraction of the launcher family. **Refactor every hardcoded path** to repo-relative:
- `$HOME/.claude/settings.local-fast.json` → `${CLAUDE_LOCAL_FAST_DIR}/claude/settings.local-fast.json`
- `$HOME/.ollama/Modelfile.<tag>` → `${CLAUDE_LOCAL_FAST_DIR}/ollama/Modelfile.<tag>`
- `$HOME/.claude/cc_proxy.py` → `${CLAUDE_LOCAL_FAST_DIR}/proxy/cc_proxy.py`
- probe logs → `${TMPDIR:-/tmp}/cc_proxy`
- Guard at top: `: "${CLAUDE_LOCAL_FAST_DIR:?source via install_shell.sh}"`.
- Do **not** hardcode the `claude` binary path; rely on the user's `PATH`. If `claude` is absent, print a friendly error pointing at `setup.sh`.

Functions to include (behavior already verified — preserve exactly):
- `_ollama_serve_tuned` — start Ollama with the 8 GB-tuned, offline-safe env: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=5m`, `OLLAMA_NO_CLOUD=1`, host `127.0.0.1:11434`. Restart only if not already running with that env.
- `_ensure_ollama_model <tag> <modelfile>` — `ollama create` if the tag is missing.
- `_claude_local_launch <tag> [args…]` — the shared full-profile env block (`ANTHROPIC_BASE_URL=http://127.0.0.1:11434`, `ANTHROPIC_AUTH_TOKEN=ollama`, all opus/sonnet/haiku tiers mapped to `<tag>`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1`, `MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192`).
- `claude-local-medium` — `qwen3-cc` + `--agent medium` (tools: Read, Write, Edit, Bash, Grep, Glob, WebFetch, WebSearch, TodoWrite, NotebookEdit; **no Task**) + `--settings … --strict-mcp-config`. ~2.7k-token prompt.
- `claude-local-full` — `_claude_local_launch qwen3-local` (all tools, ~28k).
- `claude-local` — wrapper: intercepts `-h|--h|--help` → prints the cheatsheet (the COMMAND table); else `claude-local-medium "$@"`.
- `claude-code` — `qwen3-cc` + `--agent local` (6 tools: Read/Write/Edit/Bash/Grep/Glob).
- `claude-air-fast` — `qwen3-air` + `--agent air` (8 tools: the medium set **minus WebFetch/WebSearch**, since Wi-Fi is off in flight) + pre-flight checklist echo + warm the model with `keep_alive:-1`.
- `claude-air-full` — `_claude_local_launch qwen3-air` (all tools) + pre-flight + warm.
- `claude-air` — wrapper: `-h|--h|--help` → cheatsheet; else `claude-air-fast "$@"`.
- `claude-ollama-reset` — force-restart Ollama (recovers the `count_tokens` stall, Ollama #13949).
- `claude-local-probe` — run the **full** profile through `cc_proxy.py` in probe mode (model-free) and capture the prompt; prints the 3-step instructions.
- `claude-local-prefix-diff` — diff the two captured turns' static prefix; ✅ identical ⇒ KV reuse will engage, ❌ shows the busting bytes. (Uses zsh nullglob `(N)`.)
- `claude-local-probe-stop` — `pkill -f cc_proxy.py`.

Keep the agent JSON inline in each launcher, or factor the medium/air agent definitions into `shell/agents/*.json` resolved via `$CLAUDE_LOCAL_FAST_DIR` — agent's choice.

### `proxy/cc_proxy.py`
Copy verbatim from the build machine. Stdlib-only (no pip deps), supports `CC_PROXY_MODE=probe|forward`, `CC_PROXY_PORT`, `CC_PROXY_LOG`, `CC_PROXY_UPSTREAM`, handles `/v1/messages` (streaming SSE + non-stream), `/v1/messages/count_tokens`, `/healthz`, `/api/version`. Confirm `python3 -m py_compile` passes in CI.

### `ollama/Modelfile.*`
Copy from machine. Each is `FROM qwen3:4b-instruct-2507-q4_K_M` + `PARAMETER num_ctx …`, `PARAMETER num_gpu 99`, Qwen sampling. Add a one-line comment header explaining the ctx/RAM tradeoff (12k ≈ 3.6 GB resident on 8 GB).

### `claude/settings.local-fast.json`
Copy + scrub. Keep: plugins all `false`, `disableBundledSkills:true`, `includeGitInstructions:false`, `enableAllProjectMcpServers:false`, low `skillListingBudgetFraction`. **Remove** any user-specific `claudeMdExcludes` paths (replace with generic `**/CLAUDE.md` only, or drop).

### `setup.sh` (one-command installer)
```
Usage: ./setup.sh [--yes] [--no-shell] [--shell zsh|bash] [--dir <path>] [--skip-models]
```
- `set -euo pipefail`; clear `log()/warn()/die()` helpers; colored output; everything **idempotent**.
- **Preflight:** assert macOS + Apple Silicon (`uname -m` = arm64); read total RAM, **warn loudly if < 8 GB** but continue; ensure `git`, `curl`.
- Resolve `CLAUDE_LOCAL_FAST_DIR` to the repo root (the directory of `setup.sh`).
- Call `install/deps.sh`, then `install/build_models.sh` (unless `--skip-models`), then `install/install_shell.sh` (unless `--no-shell`).
- Final message: `source ~/.zshrc`, then `claude-local --help`.

### `install/deps.sh`
Detect-then-install, each step idempotent and skippable if present:
- **Homebrew** — if missing, print the official install command and offer to run it (respect `--yes`).
- **Ollama** — `brew install ollama` if `command -v ollama` fails; verify `ollama --version`.
- **Node + npm** — if missing, warn and recommend `nvm` (do not silently install a system Node); detect `nvm` and the active node bin so `claude` lands on PATH.
- **Claude Code** — `npm install -g @anthropic-ai/claude-code` if `command -v claude` fails; verify `claude --version`.
- **python3** — verify present; cc_proxy needs no pip packages.
- Print a summary table of what was found vs installed.

### `install/build_models.sh`
- Ensure the Ollama daemon is reachable (start tuned if not).
- `ollama pull qwen3:4b-instruct-2507-q4_K_M` (skip if present; ~2.5 GB download — warn).
- For each tag: `ollama create <tag> -f "$CLAUDE_LOCAL_FAST_DIR/ollama/Modelfile.<tag>"` (skip if `ollama list` already has it; `--force` flag to rebuild).
- Verify with `ollama list`.

### `install/install_shell.sh` (THE "add to your shell" script — spec it precisely)
- Determine target rc: `--shell` flag, else `$SHELL` basename → `~/.zshrc` (zsh) / `~/.bashrc` (bash). The functions are **zsh-syntax**; if bash is requested, print a clear "zsh-only for now" warning (bash port is future work — see §10).
- **Back up** the rc to `~/.zshrc.claude-local-fast.bak.<UTC-timestamp>`.
- **Idempotent managed block** delimited by markers; on re-run, remove the old block (sed between markers) before re-adding, so updates are clean and uninstall is exact:
  ```sh
  # >>> claude-local-fast >>>
  export CLAUDE_LOCAL_FAST_DIR="<resolved repo path>"
  [ -f "$CLAUDE_LOCAL_FAST_DIR/shell/claude-local-fast.zsh" ] && source "$CLAUDE_LOCAL_FAST_DIR/shell/claude-local-fast.zsh"
  # <<< claude-local-fast <<<
  ```
- Validate after write: `zsh -n ~/.zshrc`. Print: `source ~/.zshrc` then `claude-local --help`.
- Never edit the rc outside the markers.

### `uninstall.sh`
- Remove the managed block from the rc (between markers), restore-from-backup option.
- `--purge-models` removes the 3 tuned tags (leaves base model + Ollama + Claude Code).
- Leaves Homebrew/Node/Ollama/Claude Code untouched. Idempotent.

### `hooks/help-free-ram.sh` (OPTIONAL)
A `UserPromptSubmit` hook: if the user submits exactly `help` in a **local** session (detected by `ANTHROPIC_BASE_URL` containing `:11434`), `ollama stop` all models to rescue an 8 GB box near OOM. Document as opt-in; provide the `settings.json` snippet to register it but **do not** auto-modify the user's global `settings.json` in `setup.sh` — make it a documented manual step or a `--with-emergency-hook` flag.

### `README.md` (outline)
1. One-liner + the latency table from §1.
2. **Quick start:** `git clone … && cd claude-local-fast && ./setup.sh && source ~/.zshrc && claude-local`.
3. **Command reference** = the cheatsheet table (claude-local / -full / -medium, claude-code, claude-air / -fast / -full, probe trio, claude-ollama-reset).
4. **Requirements:** macOS + Apple Silicon, ≥8 GB (8 GB supported, 16 GB comfortable), Ollama, Node 18+, Claude Code, python3.
5. **How it works** (short) → link ARCHITECTURE.md.
6. **Benchmarks** → link BENCHMARKS.md.
7. **Troubleshooting** + **Uninstall**.
8. **Credits:** Ollama, Anthropic Claude Code, Qwen3; papers arXiv:2509.07928 (cascade) and arXiv:2503.06027 (on-device survey).
9. Badges: CI status, license.

### `docs/`
- **ARCHITECTURE.md** — prefill vs decode; why a custom base URL inlines all tool schemas; the `--agent` lever; the Task-tool cost; Ollama prefix-KV reuse (token-exact prefix-from-zero, ~40× turn 2) and what busts it; why MLX loses on M1; the cascade reframe.
- **BENCHMARKS.md** — the measured numbers + exact reproduction commands (the probe method for prompt size; `/api/chat` `prompt_eval_duration` for prefill/gen tok/s; the extension test showing KV reuse).
- **TROUBLESHOOTING.md** — `count_tokens` → 404 (non-fatal, Ollama #13949) and the `claude-ollama-reset` fix; model won't fit / swap thrash on 8 GB (lower `num_ctx`, prefer medium); `claude` not on PATH (nvm); first turn slow = cold model load; the `127.0.0.1` (not `localhost`) IPv6 gotcha.

### `tests/smoke.sh` + `.github/workflows/ci.yml`
- `tests/smoke.sh`: `zsh -n shell/claude-local-fast.zsh`; `python3 -m py_compile proxy/cc_proxy.py`; `python3 -c 'json.load(...)'` on the settings file; **probe self-test** — start `cc_proxy.py` in probe mode on a test port, POST a streaming and a non-streaming `/v1/messages`, assert a canned reply + a logged `turn_*.json`, then stop it (model-free, runs in CI).
- `ci.yml`: on push/PR — `shellcheck` all `*.sh`; run `tests/smoke.sh`; `ubuntu-latest` is fine for lint + the model-free probe test (no Ollama/Claude Code needed in CI). Note in the file that end-to-end model tests require local Apple-Silicon hardware and are not run in CI.

### `.gitignore`
`*.bak.*`, `cc_proxy*.log`, `cc_proxy*` temp dirs, `.DS_Store`, editor dirs.

---

## 5. Parameterization & scrubbing rules (HARD GATE before first push)

Run a grep sweep and fail the task if any hit remains in tracked files:
- **Personal identifiers:** your name, email addresses, and any home-dir absolute path (`/Users/<name>/…`, `/home/<name>/…`) → replace with `$HOME` / `$CLAUDE_LOCAL_FAST_DIR` / `~`.
- **Unrelated projects:** names of any other local projects that shouldn't be public (maintain your own deny-list).
- **Secrets:** ensure `ANTHROPIC_AUTH_TOKEN` is the literal placeholder `ollama`, never a real key; keep `env -u ANTHROPIC_API_KEY`.
- **Git identity:** commit with a `noreply` email, not a personal address.
- Suggested gate (extend with your own private names):
  `! git grep -nIE '(/Users/[^/]+/|/home/[^/]+/|sk-ant-|AKIA[0-9A-Z]{16})' -- .`

---

## 6. Install flow (ordered)

```
setup.sh
 ├─ preflight (macOS arm64, RAM warn, git/curl)
 ├─ install/deps.sh        → Homebrew, Ollama, Node+npm, Claude Code, python3
 ├─ install/build_models.sh→ pull base model, create qwen3-cc / -local / -air
 └─ install/install_shell.sh→ backup rc, write managed block, zsh -n validate
→ user runs: source ~/.zshrc ; claude-local --help
```

---

## 7. Testing & acceptance criteria (Definition of Done)

1. `./setup.sh --skip-models --no-shell` runs clean on a fresh checkout (deps detected).
2. `tests/smoke.sh` passes locally and in CI (lint + probe self-test).
3. After `install/install_shell.sh` + `source`, all functions resolve (`whence -w claude-local …`) and `claude-local --help` prints the cheatsheet (does **not** launch Claude Code).
4. On Apple-Silicon hardware (manual, document — don't gate CI): `claude-local -p "Reply with exactly: OK"` returns in **≤ ~30 s** with `input_tokens ≈ 2.7k`; `claude-local-full` shows ~25k input tokens (the contrast).
5. `claude-local-probe` → `claude-local-prefix-diff` runs model-free and prints a ✅/❌ verdict.
6. `uninstall.sh` removes the managed block and leaves the rc otherwise byte-identical to its backup.
7. Scrub gate (§5) returns no hits.
8. README quick-start works copy-paste on a clean machine.

---

## 8. Ordered task checklist for the agent

1. (If the repo doesn't already exist) create it: `gh repo create <GH_OWNER>/claude-local-fast --public --description "…" --clone`; `cd claude-local-fast`.
2. Add `LICENSE` (MIT, current year, owner = GH login), `.gitignore`, dir scaffolding.
3. **Harvest** all §2 source files into place.
4. Parameterize `shell/claude-local-fast.zsh` and refactor paths to `$CLAUDE_LOCAL_FAST_DIR`; `zsh -n` it.
5. Copy `cc_proxy.py`; scrub `settings.local-fast.json`; copy the 3 Modelfiles.
6. Write `install/deps.sh`, `install/build_models.sh`, `install/install_shell.sh`, `setup.sh`, `uninstall.sh`.
7. Write `docs/*` (pull numbers from BENCHMARKS source; harvest HANDOFF and scrub).
8. Write `tests/smoke.sh` and `.github/workflows/ci.yml`.
9. Write `README.md`.
10. Run the **scrub gate** (§5) and `tests/smoke.sh`; fix until green.
11. Commit in logical chunks (noreply email); push; confirm CI passes.
12. PR/commit description: list anything generated-from-spec (missing sources), and the manual Apple-Silicon acceptance steps (criteria 4–6) the maintainer should run once.

Commit trailer to use:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## 9. Design decisions (already made — don't relitigate)
- **Source-from-clone**, not copy-to-`~/.claude`: the shell file, proxy, Modelfiles, and settings all live in the repo and are referenced via `$CLAUDE_LOCAL_FAST_DIR`, so `git pull` updates everything. `install_shell.sh` only adds a 3-line managed block to the rc.
- **zsh-first** (matches the launchers' syntax). Bash port is explicitly future work.
- **Bare names default to fast**: `claude-local`→medium, `claude-air`→air-fast; `-full` variants are the escape hatches.
- **CI is lint + model-free probe only**; real model runs need local Apple-Silicon hardware.

## 10. Known risks / gaps to call out in the PR
- **Model-tag coupling:** Anthropic resolves the tool-search "unsupported models" list from a remote flag; tool-deferral behavior on custom endpoints can change across Claude Code versions. Pin a tested `claude --version` in README and note it.
- **8 GB is marginal:** two resident models won't fit; keep `OLLAMA_MAX_LOADED_MODELS=1`; never pin `OLLAMA_KEEP_ALIVE=-1` globally (RAM-crash risk).
- **Bash users** get a warning, not functions, until the port lands.
- **`help-free-ram.sh`** edits global Claude Code `settings.json` — keep it opt-in, never automatic.
- **First-turn latency** is cold model load (~20–90 s) on top of prefill; document so users don't read it as a regression.

---

## Appendix: reproduction snippets for BENCHMARKS.md
- **Prompt size (model-free):** start `cc_proxy.py` in probe mode, point a `claude -p "hi" --output-format json` invocation (with the launcher's flags) at it, read `turn_*.json` `tool_bytes` / `num_tools`.
- **Prefill/decode tok/s:** `curl 127.0.0.1:11434/api/chat -d '{"model":"qwen3-cc","stream":false,"messages":[…],"options":{"num_predict":16}}'` → `prompt_eval_count / prompt_eval_duration` and `eval_count / eval_duration`.
- **KV reuse:** two `/api/chat` calls where call 2's messages strictly **extend** call 1's; reuse shows as `prompt_eval_duration` collapsing (~20 s → ~0.3–0.5 s) while `prompt_eval_count` stays full.
