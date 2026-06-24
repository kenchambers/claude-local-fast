# Airplane mode + KV-cache reuse — operational guide

Run Claude Code fully offline on a local model at 35,000 ft, with the prefix-KV
reuse optimization **on by default** so warm turns are near-instant and the
battery lasts. This is the end-to-end runbook: what to do on the ground, what
runs in flight, how to confirm the optimization is engaged, and how to recover
if something stalls.

If you only read one thing:

```bash
# ON THE GROUND (Wi-Fi still on) — build + warm the model so nothing downloads in flight:
claude-air -p "Reply with exactly: OK"      # builds qwen3-air the first time, warms the slot

# IN FLIGHT (Wi-Fi off):
claude-air                                  # fast airplane profile, KV-reuse ON by default
# ...work...
claude-local-stop                           # free ~4 GB RAM when done (also auto-runs on shell exit)
```

---

## 1. The two airplane launchers

| Command | Model | Tools | Prompt | When |
|---|---|---|---|---|
| `claude-air` → `claude-air-fast` | `qwen3-air` | 8 (Read/Write/Edit/Bash/Grep/Glob/TodoWrite/NotebookEdit — **no** Task, **no** web) | ~4k tok | default; fast, battery-friendly |
| `claude-air-full` | `qwen3-air` | ALL built-in tools (incl. `Task`) | ~28k tok | only when you truly need every tool offline |

Both are **offline-hardened**: `127.0.0.1` everywhere (never `localhost` — it
resolves IPv6-first on macOS and stalls), the opus/sonnet/haiku tiers are all
mapped to the local tag (so background tier calls don't 404 and look like a
hang), a dummy auth token, and telemetry / auto-update / non-essential model
calls off. Web tools are dropped from the fast profile because Wi-Fi is off.

Both also **pin the model resident** for the session (`keep_alive:-1` via a warm
call) so it never unloads mid-flight, and both **route through the KV-reuse
proxy by default** (next section).

---

## 2. The KV-cache optimization (why airplane defaults it ON)

**The problem.** Claude Code injects a per-request nonce at the *front* of the
system prompt:

```
anthropic-billing-header: cc_version=2.1.170.<hex>; cc_entrypoint=sdk-cli; cch=<hex>;
                                              ^^^^^                            ^^^^^
                                  per-PROCESS build suffix            per-REQUEST nonce
```

`cch=<hex>` changes on **every** request. Because it sits ~74 bytes into the
prompt, it invalidates essentially the whole prefix, so Ollama re-prefills the
full prompt **every turn** — on the fast air profile *and* `claude-air-full`.
(Confirmed on all three profiles: full / medium / air.)

**The fix.** A tiny localhost proxy — `proxy/cc_proxy.py` in **forward+normalize**
mode — rewrites that nonce (and the `cc_version` build suffix) to a constant
before relaying to Ollama. Ollama ignores billing headers, so instructions,
tool schemas, and messages are byte-for-byte unchanged; only the nonce is
neutralized. The prefix becomes byte-stable, and Ollama reuses its KV cache.

**Why ON by default for airplane (but opt-in elsewhere):**

- **In flight, prefill is pure battery-burning compute.** Reusing the prefix is
  the single biggest lever on both latency *and* battery.
- **The proxy is localhost-only** (`127.0.0.1:11436` → `127.0.0.1:11434`). It
  never touches the network, so it is completely offline-safe.
- **It fails open.** If `python3` is missing or the proxy can't start, the
  launcher prints a warning and falls back to talking to Ollama directly — you
  lose the reuse, not the session.

The online launchers (`claude-local` / `-medium` / `-full` / `claude-code`) keep
this **opt-in** (`CLAUDE_LOCAL_FAST_NORMALIZE=1`) while the proxy burns in as a
reliability surface. Airplane opts in for you because the battery win matters
most there.

> **Measured impact.** On the comparable medium profile (warm model, A/B that
> differs *only* in the `cch` nonce): turn-2 prefill **27.5 s → 0.4 s (~78×)**.
> That headline is **prefill-only**; end-to-end per warm turn it's ~2.4× / about
> **~20 s saved per warm turn** (decode is unchanged). On `claude-air-full` the
> reused prefix is the whole ~28k-token tool-schema block, so the absolute
> saving per warm turn is larger. See [BENCHMARKS.md](BENCHMARKS.md).

---

## 3. Pre-flight checklist (do this with Wi-Fi still ON)

Nothing here can be done at altitude, so do it at the gate:

1. **Build the air model once.** First run of `claude-air` builds `qwen3-air`
   from its Modelfile (one-time, needs network for the base pull). Force it now:
   ```bash
   claude-air -p "Reply with exactly: OK"
   ollama list | grep qwen3-air          # confirm the tag exists
   ```
2. **Confirm `python3` is present** (required for the reuse proxy — there's no
   installing it mid-flight):
   ```bash
   command -v python3 || echo "no python3 → airplane still works, but WITHOUT KV-reuse"
   ```
3. **Confirm the model stays 100% on the GPU** (no CPU spill on 8 GB):
   ```bash
   ollama ps                              # the % should read 100% GPU
   ```
4. **Battery prep:** Low Power Mode ON, brightness ~40%, quit Chrome/Docker and
   other big RAM users.
5. **Now** turn on Airplane Mode / Wi-Fi OFF.

`claude-air` prints an abbreviated version of this as a pre-flight banner each
time you launch it.

---

## 4. A full in-flight session, step by step

```bash
# 1. Launch the fast airplane profile. This will, in order:
#    • start/verify the tuned Ollama daemon on 127.0.0.1:11434
#    • build qwen3-air if missing (already done pre-flight)
#    • warm + pin the model (keep_alive:-1) so it won't unload mid-flight
#    • start the KV-reuse proxy on 127.0.0.1:11436 (forward+normalize)
#    • launch Claude Code pointed at the proxy
claude-air

# 2. Work normally. Turn 1 still pays a full (cold) prefill — the prefix has no
#    prior to reuse yet. From turn 2 on, the normalized prefix is reused and
#    prefill collapses.

# 3. Need every tool (Task, etc.) offline? Use the full airplane profile instead:
claude-air-full
#    (~28k prompt, slow first turn — but warm turns still reuse the prefix.)

# 4. Done flying / want the RAM back now:
claude-local-stop
```

You don't have to manage the proxy or the daemon — the launcher starts what it
needs and the shell cleans both up on exit (see §7).

---

## 5. The moving parts (ports & processes)

| Port | Process | Started by | Role |
|---|---|---|---|
| `11434` | `ollama serve` (tuned) | `_ollama_serve_tuned` | the model backend |
| `11436` | `cc_proxy.py` forward+normalize | `claude-air` (default-on) | strips the `cch` nonce → KV reuse |
| `11435` | `cc_proxy.py` probe | `claude-local-probe` only | model-free measurement (not used in a real session) |

Logs (under `${TMPDIR:-/tmp}/cc_proxy/`, overridable via
`CLAUDE_LOCAL_FAST_PROBE_LOG`):

- `summary.log` — one line per turn with the `prefix_stable` verdict + `norm=` count.
- `turn_NNN.json` / `turn_NNN.timing.json` — per-turn fingerprints and upstream latency.
- `${TMPDIR:-/tmp}/cc_proxy.fwd.log` — the reuse proxy's own server log.

---

## 6. Toggles & environment variables

| Variable | Default (airplane) | Effect |
|---|---|---|
| `CLAUDE_LOCAL_FAST_NORMALIZE` | **on** for `claude-air*` | `0`/`false`/`no`/`off` → force the reuse proxy OFF (even on airplane); `1`/`true`/`yes`/`on` → force ON. Unset → airplane defaults ON, online defaults OFF. |
| `CLAUDE_LOCAL_FAST_NO_AUTOSTOP` | unset | Set to `1` to keep the Ollama daemon resident across shell exits (skip the auto-stop). |
| `OLLAMA_KEEP_ALIVE` | `5m` (serve default) | Idle unload timer for the *model*. The air launchers separately pin `qwen3-air` with `keep_alive:-1` so it won't unload mid-flight regardless. |
| `CLAUDE_LOCAL_FAST_PROBE_LOG` | `${TMPDIR:-/tmp}/cc_proxy` | Where telemetry + proxy logs are written. |

Turn the optimization **off** for one session (e.g. to isolate a problem):

```bash
CLAUDE_LOCAL_FAST_NORMALIZE=0 claude-air      # talks to Ollama directly, no proxy
```

---

## 7. RAM & battery hygiene

`OLLAMA_KEEP_ALIVE=5m` only unloads the **model** after idle; the `ollama serve`
daemon — plus the pinned `qwen3-air` (`keep_alive:-1`) and the reuse proxy — stay
resident until you stop them. So **the shell that started them stops them on
exit**: it unloads every model (frees the ~4 GB), kills the daemon and any
orphaned runner, and stops the reuse proxy it started. Only the *owner* shell
does this — a daemon from Ollama.app or `brew services` is left alone.

```bash
claude-local-stop                  # free RAM now without closing the shell
export CLAUDE_LOCAL_FAST_NO_AUTOSTOP=1   # opt out of auto-stop (keep it resident)
```

---

## 8. Verify the optimization is actually engaged

After a couple of turns in a session:

```bash
grep prefix_stable "${TMPDIR:-/tmp}/cc_proxy/summary.log"
```

- **Turn 1:** no prior to compare against (no verdict / `prefix_stable=` absent).
- **Turn 2+:** `prefix_stable=yes` with `norm=2` (the two nonce spans were
  rewritten). That's the win — the prefix is now reuse-eligible and Ollama skips
  re-prefilling it.
- If you see `prefix_stable=no`, the optimization is **not** engaged — see §9.

Confirm the model is resident and on the GPU (so the reused slot stays warm):

```bash
ollama ps        # qwen3-air, 100% GPU, "Forever" / keep-alive pinned
```

Want to prove the buster/fix model-free (no model load, RAM-safe)? On the
ground:

```bash
claude-local-probe          # send 2 prompts in the SAME session, then Ctrl-C
claude-local-prefix-diff    # ❌ shows the busting bytes; with normalize → ✅ identical
claude-local-probe-stop
```

---

## 9. Troubleshooting in flight

**A turn hangs / `count_tokens` 404s.** Ollama's compat endpoint can stall
(Ollama #13949). Recover without losing the model build:

```bash
claude-ollama-reset      # force-restart Ollama on 127.0.0.1:11434
```

**`prefix_stable=no` (no reuse).** Most likely the proxy didn't come up so the
launcher fell back to direct Ollama. Check:

```bash
curl -s http://127.0.0.1:11436/healthz || echo "reuse proxy not running"
cat "${TMPDIR:-/tmp}/cc_proxy.fwd.log"          # why it failed (often: no python3)
command -v python3                               # the proxy needs it
```

If `python3` is missing you're flying without reuse (still functional, just
slow warm turns) — there's no fix at altitude; install `python3` next time on
the ground. If the header format changed (a Claude Code update), the normalizer
logs `norm=0` instead of `norm=2` — the nonce stopped matching the patterns; the
telemetry flags it and reuse won't engage until the patterns are updated.

**Everything swaps / fan spins (8 GB).** The model must stay 100% on the GPU.
Prefer `claude-air` over `claude-air-full`, quit other RAM hogs, and verify with
`ollama ps`. Don't raise `num_ctx`. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#model-wont-fit--fan-spins--everything-swaps-8-gb).

**It hangs at connect, especially offline.** That's the `localhost` IPv6 trap —
the launchers already pin `127.0.0.1`; don't override `ANTHROPIC_BASE_URL` with
`localhost`.

**The model answers in prose instead of using tools.** Phrase requests as
concrete tasks ("Read `setup.sh` and summarize it", not "can you see my
files?"). Full detail in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-model-answers-in-prose-instead-of-using-tools).

---

## 10. See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — prefill vs decode, the `--agent` lever,
  Ollama prefix-KV reuse, and the billing-header buster in depth.
- [BENCHMARKS.md](BENCHMARKS.md) — the measured numbers and how to reproduce them.
- [../plans/KV_CACHE_REUSE_PLAN.md](../plans/KV_CACHE_REUSE_PLAN.md) — full method,
  A/B harness, and prefix-stability telemetry.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — every failure mode and its recovery.
