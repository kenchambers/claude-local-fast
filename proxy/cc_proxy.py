#!/usr/bin/env python3
"""
cc_proxy.py — tiny local proxy/probe between Claude Code and Ollama.

WHY: full `claude-local` re-prefills a ~28k-token tool-schema prefix every
turn (~2 min) on an 8GB M1. Ollama's KV cache CAN reuse that prefix (~40x
faster on turn 2) — but ONLY if the front of the prompt is byte-identical
turn-to-turn. Claude Code injects per-turn dynamic content that may bust it.
This proxy lets you (1) PROVE whether the prefix is stable (probe mode), and
(2) NORMALIZE the measured busters so reuse engages (CC_PROXY_NORMALIZE=1).

Measured buster (Claude Code 2.1.x): an `anthropic-billing-header` at the very
FRONT of the system prompt carries `cch=<hex>` — a per-request nonce that
changes every turn (even within one --continue session) — plus a per-process
`cc_version=X.Y.Z.<hex>` build suffix. Both sit ~74 bytes in, so they re-prefill
the entire ~5-28k-token prefix every turn. Ollama is not Anthropic and ignores
these, so rewriting them to a constant restores a byte-stable prefix without
changing the model's instructions.

Modes (env CC_PROXY_MODE):
  probe   (default): log each /v1/messages request's static prefix
                     (system + tools) and return a canned valid Anthropic
                     reply WITHOUT touching Ollama. Model-free, instant,
                     RAM-safe. Use to diff turn-to-turn prefix stability.
  forward          : transparently forward to Ollama and log the same
                     fingerprints (buffered; SSE is relayed non-streaming
                     for now — fine for diagnostics). Also records, per turn,
                     the upstream wall-clock latency + any prefill/usage
                     fields the backend returns — turn-2 latency collapse is
                     the cache-HIT signal (ollama/ollama#2068: on a hit
                     prompt_eval_count can drop out, so watch the DURATION,
                     not the count).

Telemetry (both modes): every real /v1/messages turn records
`prefix_stable_vs_prev` — whether its static prefix (system+tools) is
byte-identical to the previous such turn. That byte-stability is the
PRECONDITION for Ollama prefix-KV reuse, so the verdict is now permanent
and automatic (no manual claude-local-prefix-diff step needed). Read it in
summary.log or turn_NNN.json (true = reuse-eligible, false = prefix busted).

Env:
  CC_PROXY_MODE=probe|forward      (default probe)
  CC_PROXY_PORT=11435              (listen port)
  CC_PROXY_LOG=/tmp/cc_proxy       (where turn_NNN.* + summary.log land)
  CC_PROXY_UPSTREAM=http://127.0.0.1:11434   (Ollama, forward mode only)
  CC_PROXY_TIMEOUT_SEC=600         (upstream read timeout, forward mode only)
  CC_PROXY_NORMALIZE=0|1           (rewrite per-request prefix nonces to a
                                    constant before logging+forwarding; default
                                    off → transparent passthrough)
"""
import os, json, re, time, hashlib, threading, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE     = os.environ.get("CC_PROXY_MODE", "probe")
PORT     = int(os.environ.get("CC_PROXY_PORT", "11435"))
LOGDIR   = os.environ.get("CC_PROXY_LOG", "/tmp/cc_proxy")
UPSTREAM = os.environ.get("CC_PROXY_UPSTREAM", "http://127.0.0.1:11434")
# Upstream read timeout (forward mode). Default is generous because the first
# turn re-prefills a ~28k-token tool schema, which can take ~2 min on an 8GB M1.
# Lower it via CC_PROXY_TIMEOUT_SEC to bound how long a stalled upstream can pin
# a request thread.
UPSTREAM_TIMEOUT = float(os.environ.get("CC_PROXY_TIMEOUT_SEC", "600"))
os.makedirs(LOGDIR, exist_ok=True)

# ── Prefix normalization (opt-in: CC_PROXY_NORMALIZE=1) ──────────────────────
# Claude Code injects per-request nonces at the FRONT of the system prompt (an
# `anthropic-billing-header`) that bust Ollama prefix-KV reuse every turn — see
# the module docstring. Rewriting them to a constant restores a byte-stable
# prefix. The patterns only match inside that header's string value, so the JSON
# stays valid; each is idempotent (the constant contains no hex, so it won't
# re-match). If Claude Code changes the header format, the patterns simply stop
# matching (norm=0 in summary.log) and the prefix-stability telemetry flags it.
NORMALIZE = os.environ.get("CC_PROXY_NORMALIZE", "0").lower() not in ("", "0", "false", "no")
_NORM_PATTERNS = (
    (re.compile(r"cch=[0-9a-f]+"), "cch=NORMALIZED"),
    (re.compile(r"(cc_version=\d+\.\d+\.\d+\.)[0-9a-f]+"), r"\1NORMALIZED"),
)

def _normalize_raw(raw):
    """Rewrite known per-request prefix-busting nonces to constants.
    Returns (new_raw_bytes, total_substitutions). No-ops (returns raw unchanged)
    on decode failure or zero matches."""
    try:
        s = raw.decode("utf-8")
    except Exception:
        return raw, 0
    total = 0
    for rx, repl in _NORM_PATTERNS:
        s, n = rx.subn(repl, s)
        total += n
    return (s.encode("utf-8") if total else raw), total

_seq_lock = threading.Lock()
_seq = 0
def _next_seq():
    global _seq
    with _seq_lock:
        _seq += 1
        return _seq

# Turn-to-turn prefix-stability tracker. Only real /v1/messages turns update it
# (count_tokens shares the same prefix and would interleave, so it's excluded).
_front_lock = threading.Lock()
_last_msgs_front_sha = None

def _sha(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()

def log_request(body, beta, track_stability=False, norm_subs=None):
    """Persist the static prefix (system+tools) + per-message fingerprints.

    When track_stability is set (real /v1/messages turns), also record whether
    this turn's static prefix is byte-identical to the previous such turn —
    `prefix_stable_vs_prev`. That byte-stability is the precondition for Ollama
    prefix-KV reuse, so the verdict is permanent telemetry rather than a manual
    prefix-diff step. count_tokens turns pass track_stability=False so they
    don't pollute the comparison (they share the same prefix)."""
    seq = _next_seq()
    system   = body.get("system", "")
    tools    = body.get("tools", [])
    messages = body.get("messages", [])
    sys_str   = json.dumps(system, ensure_ascii=False)
    tools_str = json.dumps(tools, ensure_ascii=False)
    front = sys_str + "\n---TOOLS---\n" + tools_str
    front_sha = _sha(front)

    prev_front_sha = None
    prefix_stable = None   # None until there's a prior tracked turn to compare to
    if track_stability:
        global _last_msgs_front_sha
        with _front_lock:
            prev_front_sha = _last_msgs_front_sha
            _last_msgs_front_sha = front_sha
        if prev_front_sha is not None:
            prefix_stable = (prev_front_sha == front_sha)

    with open(os.path.join(LOGDIR, f"turn_{seq:03d}.front.txt"), "w") as f:
        f.write(front)
    msg_fp = []
    for i, m in enumerate(messages):
        cs = json.dumps(m.get("content", ""), ensure_ascii=False)
        msg_fp.append({"i": i, "role": m.get("role"), "len": len(cs), "sha8": _sha(cs)[:8]})
    summary = {
        "seq": seq, "model": body.get("model"), "stream": bool(body.get("stream")),
        "num_tools": len(tools) if isinstance(tools, list) else 0,
        "tool_bytes": len(tools_str), "system_bytes": len(sys_str),
        "front_sha256": front_sha, "anthropic_beta": beta,
        "prev_front_sha256": prev_front_sha, "prefix_stable_vs_prev": prefix_stable,
        "normalized_tokens": norm_subs,
        "num_messages": len(messages), "messages": msg_fp,
    }
    with open(os.path.join(LOGDIR, f"turn_{seq:03d}.json"), "w") as f:
        json.dump(summary, f, indent=1)
    if not track_stability:
        mark = "n/a"
    elif prefix_stable is None:
        mark = "first"
    else:
        mark = "yes" if prefix_stable else "no"
    norm_str = f" norm={norm_subs}" if norm_subs is not None else ""
    with open(os.path.join(LOGDIR, "summary.log"), "a") as f:
        f.write(f"turn {seq:03d} | tools={summary['num_tools']:>2} "
                f"tool_bytes={summary['tool_bytes']:>6} sys_bytes={summary['system_bytes']:>6} "
                f"msgs={summary['num_messages']:>2} front_sha={front_sha[:12]} "
                f"prefix_stable={mark:<5}{norm_str} beta={beta or '-'}\n")
    return summary

def _log_forward_timing(summary, elapsed_ms, data, ctype, ttfb_ms=None):
    """Forward mode: record the per-turn cache-HIT outcome signal next to the
    request fingerprint. The headline is upstream wall-clock latency (it
    collapses ~40x on a prefix-KV reuse); prompt_eval_duration is parsed
    defensively because only Ollama's NATIVE /api/chat shape carries it — the
    Anthropic-compat /v1/messages shape exposes usage.{input,output}_tokens but
    no prefill timing. Per ollama/ollama#2068 the reliable hit signal is the
    DURATION collapsing, not the token count (which can drop out on a hit)."""
    if not summary:
        return
    seq = summary.get("seq")
    rec = {
        "seq": seq,
        "upstream_ms": round(elapsed_ms, 1),
        "upstream_ttfb_ms": round(ttfb_ms, 1) if ttfb_ms is not None else None,
        "front_sha256": summary.get("front_sha256"),
        "prefix_stable_vs_prev": summary.get("prefix_stable_vs_prev"),
    }
    if "json" in (ctype or "").lower():
        try:
            body = json.loads(data)
        except Exception:
            body = None
        if isinstance(body, dict):
            for k in ("prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration"):
                if k in body:
                    rec[k] = body[k]
            usage = body.get("usage")
            if isinstance(usage, dict):
                for k in ("input_tokens", "output_tokens"):
                    if k in usage:
                        rec["usage_" + k] = usage[k]
    ped = rec.get("prompt_eval_duration")
    if isinstance(ped, (int, float)):
        rec["prefill_seconds"] = round(ped / 1e9, 3)   # Ollama reports nanoseconds
    if seq is not None:
        with open(os.path.join(LOGDIR, f"turn_{seq:03d}.timing.json"), "w") as f:
            json.dump(rec, f, indent=1)
    prefill = rec.get("prefill_seconds")
    ttfb = rec.get("upstream_ttfb_ms")
    seq_str = f"{seq:03d}" if seq is not None else "?"
    with open(os.path.join(LOGDIR, "summary.log"), "a") as f:
        f.write(f"  forward seq={seq_str} upstream={rec['upstream_ms']:.0f}ms"
                + (f" ttfb={ttfb:.0f}ms" if ttfb is not None else "")
                + (f" prefill={prefill:.3f}s" if prefill is not None else "")
                + "\n")

def _canned(model):
    return {
        "id": "msg_probe", "type": "message", "role": "assistant", "model": model or "probe",
        "content": [{"type": "text", "text": "(probe: prefix logged; no model invoked. "
                                             "Send another prompt, then Ctrl-C and run claude-local-prefix-diff.)"}],
        "stop_reason": "end_turn", "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 16},
    }

def _sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, format, *args):  # silence default access log
        pass

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/healthz"):
            self._json({"ok": True, "mode": MODE}); return
        if self.path.startswith("/api/version"):
            self._json({"version": "cc-proxy"}); return
        self._json({"ok": True})

    def do_POST(self):
        try:
            ln  = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(ln) if ln else b""
            beta = self.headers.get("anthropic-beta")
            try:
                body = json.loads(raw) if raw else {}
            except Exception:
                body = {}

            is_msgs  = self.path.startswith("/v1/messages") and "count_tokens" not in self.path
            is_count = "count_tokens" in self.path

            # Normalize ONCE, before both logging and forwarding, so the
            # prefix-stability telemetry reflects the fix and Ollama receives the
            # byte-stable bytes. Default off → `raw`/`body` are untouched.
            norm_subs = None
            if NORMALIZE and (is_msgs or is_count) and raw:
                raw, norm_subs = _normalize_raw(raw)
                try:
                    body = json.loads(raw) if raw else {}
                except Exception:
                    body = {}

            summary = None
            if is_msgs or is_count:
                try:
                    summary = log_request(body, beta, track_stability=is_msgs, norm_subs=norm_subs)
                except Exception as e:
                    # Probe logging is the whole point in probe mode; surface
                    # failures to stderr instead of letting them vanish.
                    print(f"[cc_proxy] log_request failed: {e}", flush=True)

            if MODE == "forward":
                self._forward(raw, summary); return

            # ---- PROBE mode: answer locally, never load the model ----
            if is_count:
                self._json({"input_tokens": len(raw) // 4}); return
            if is_msgs:
                model = body.get("model")
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    msg = _canned(model)
                    self.wfile.write(_sse("message_start", {"type": "message_start", "message": {
                        **msg, "content": [], "stop_reason": None,
                        "usage": {"input_tokens": 1, "output_tokens": 1}}}))
                    self.wfile.write(_sse("content_block_start", {"type": "content_block_start", "index": 0,
                        "content_block": {"type": "text", "text": ""}}))
                    self.wfile.write(_sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                        "delta": {"type": "text_delta", "text": msg["content"][0]["text"]}}))
                    self.wfile.write(_sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
                    self.wfile.write(_sse("message_delta", {"type": "message_delta",
                        "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                        "usage": {"output_tokens": 16}}))
                    self.wfile.write(_sse("message_stop", {"type": "message_stop"}))
                    self.wfile.flush()
                    self.close_connection = True
                    return
                self._json(_canned(model)); return
            self._json({"ok": True})
        except Exception as e:
            try:
                self._json({"error": str(e)}, 500)
            except Exception:
                pass

    def _forward(self, raw, summary=None):
        req = urllib.request.Request(UPSTREAM + self.path, data=raw, method="POST")
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length"):
                continue
            req.add_header(k, v)
        t0 = time.monotonic()
        try:
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception as e:
            self._json({"error": str(e)}, 502); return
        code = getattr(resp, "status", None) or getattr(resp, "code", 200)
        ctype = resp.headers.get("Content-Type", "application/json")
        ttfb_ms = None
        if "event-stream" in (ctype or "").lower():
            # SSE: relay chunks as they arrive so token streaming is preserved
            # (close-delimited, no Content-Length — the body ends when we close).
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            buf = bytearray()
            # read1() returns whatever a single underlying read yields, so trickled
            # SSE events relay immediately. Plain read(n) would block until n bytes
            # or EOF, coalescing the stream back into one buffered blob.
            reader = resp.read1 if hasattr(resp, "read1") else resp.read
            while True:
                chunk = reader(65536)
                if not chunk:
                    break
                if ttfb_ms is None:
                    ttfb_ms = (time.monotonic() - t0) * 1000.0  # ≈ prefill time
                try:
                    self.wfile.write(chunk); self.wfile.flush()
                except Exception:
                    break
                buf += chunk
            data = bytes(buf)
        else:
            # Non-stream JSON: buffer and send with Content-Length (as before).
            data = resp.read()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
        self.close_connection = True
        elapsed_ms = (time.monotonic() - t0) * 1000.0
        # Record the cache-HIT outcome signal: upstream latency / TTFB (both
        # collapse on a reuse) + any prefill/usage fields. Never break the proxy.
        try:
            _log_forward_timing(summary, elapsed_ms, data, ctype, ttfb_ms=ttfb_ms)
        except Exception as e:
            print(f"[cc_proxy] forward timing log failed: {e}", flush=True)

def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"cc_proxy listening on 127.0.0.1:{PORT} mode={MODE} upstream={UPSTREAM} log={LOGDIR}")
    srv.serve_forever()

if __name__ == "__main__":
    main()
