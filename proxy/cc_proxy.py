#!/usr/bin/env python3
"""
cc_proxy.py — tiny local proxy/probe between Claude Code and Ollama.

WHY: full `claude-local` re-prefills a ~28k-token tool-schema prefix every
turn (~2 min) on an 8GB M1. Ollama's KV cache CAN reuse that prefix (~40x
faster on turn 2) — but ONLY if the front of the prompt is byte-identical
turn-to-turn. Claude Code injects per-turn dynamic content that may bust it.
This proxy lets you (1) PROVE whether the prefix is stable (probe mode), and
(2) later NORMALIZE it so reuse always engages (forward mode).

Modes (env CC_PROXY_MODE):
  probe   (default): log each /v1/messages request's static prefix
                     (system + tools) and return a canned valid Anthropic
                     reply WITHOUT touching Ollama. Model-free, instant,
                     RAM-safe. Use to diff turn-to-turn prefix stability.
  forward          : transparently forward to Ollama and log the same
                     fingerprints (buffered; SSE is relayed non-streaming
                     for now — fine for diagnostics).

Env:
  CC_PROXY_MODE=probe|forward      (default probe)
  CC_PROXY_PORT=11435              (listen port)
  CC_PROXY_LOG=/tmp/cc_proxy       (where turn_NNN.* + summary.log land)
  CC_PROXY_UPSTREAM=http://127.0.0.1:11434   (Ollama, forward mode only)
  CC_PROXY_TIMEOUT_SEC=600         (upstream read timeout, forward mode only)
"""
import os, json, hashlib, threading, urllib.request, urllib.error
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

_seq_lock = threading.Lock()
_seq = 0
def _next_seq():
    global _seq
    with _seq_lock:
        _seq += 1
        return _seq

def _sha(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()

def log_request(body, beta):
    """Persist the static prefix (system+tools) + per-message fingerprints."""
    seq = _next_seq()
    system   = body.get("system", "")
    tools    = body.get("tools", [])
    messages = body.get("messages", [])
    sys_str   = json.dumps(system, ensure_ascii=False)
    tools_str = json.dumps(tools, ensure_ascii=False)
    front = sys_str + "\n---TOOLS---\n" + tools_str
    front_sha = _sha(front)
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
        "num_messages": len(messages), "messages": msg_fp,
    }
    with open(os.path.join(LOGDIR, f"turn_{seq:03d}.json"), "w") as f:
        json.dump(summary, f, indent=1)
    with open(os.path.join(LOGDIR, "summary.log"), "a") as f:
        f.write(f"turn {seq:03d} | tools={summary['num_tools']:>2} "
                f"tool_bytes={summary['tool_bytes']:>6} sys_bytes={summary['system_bytes']:>6} "
                f"msgs={summary['num_messages']:>2} front_sha={front_sha[:12]} beta={beta or '-'}\n")
    return summary

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
            if is_msgs or is_count:
                try:
                    log_request(body, beta)
                except Exception as e:
                    # Probe logging is the whole point in probe mode; surface
                    # failures to stderr instead of letting them vanish.
                    print(f"[cc_proxy] log_request failed: {e}", flush=True)

            if MODE == "forward":
                self._forward(raw); return

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

    def _forward(self, raw):
        req = urllib.request.Request(UPSTREAM + self.path, data=raw, method="POST")
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length"):
                continue
            req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
            code, data = resp.status, resp.read()
            ctype = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            code, data, ctype = e.code, e.read(), e.headers.get("Content-Type", "application/json")
        except Exception as e:
            self._json({"error": str(e)}, 502); return
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"cc_proxy listening on 127.0.0.1:{PORT} mode={MODE} upstream={UPSTREAM} log={LOGDIR}")
    srv.serve_forever()

if __name__ == "__main__":
    main()
