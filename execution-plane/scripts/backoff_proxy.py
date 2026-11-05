#!/usr/bin/env python3
"""
backoff_proxy.py — Phase 5 (T2): exponential-backoff HTTP proxy for adapter
targets (ADR-05, #6596).

Why: the real Paperclip adapter code is upstream (ghcr.io image) and exposes
no retry/backoff fields in its adapter schema (verified: only `timeoutSec`
and `eventReconnectMs` exist). The spec accepts a wrapping HTTP client/proxy
in front of the adapter targets — this is it.

Semantics (spec §Phase 5 / #6596):
  * Retries with exponential backoff (base 2 s, factor 2, +/-20% jitter,
    max 6 retries by default) — but ONLY on connect-level failures
    (refused / unreachable / DNS). A response received from upstream is
    NEVER retried (protects non-idempotent POSTs from double-run creation).
  * Offline suspension: after the first connect failure the proxy enters
    OFFLINE mode. While offline, requests fail fast with 503 + Retry-After
    (no upstream storm); a periodic background probe restores traffic the
    moment the target is reachable again (idempotent reconnect — in-flight
    requests are not duplicated).
  * Storm metrics: requests/min per listener; a WARNING is logged when the
    rate exceeds the threshold (run-creation storm detector during outages).
  * Every action is logged (no silent failures).

Endpoints on each listener:
    /__health          — proxy health + stats (GET, always local)
    /<path>            — reverse-proxied to the configured target

Usage:
    python3 backoff_proxy.py --listen 127.0.0.1:13284 --target http://127.0.0.1:3284
    python3 backoff_proxy.py --listen 127.0.0.1:18642 --target http://127.0.0.1:8642 \
        --max-retries 6 --base-delay 2.0 --probe-interval 5

env: BACKOFF_PROXY_BASE_DELAY, BACKOFF_PROXY_MAX_RETRIES
"""

import argparse
import json
import os
import random
import sys
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

BASE_DELAY = float(os.environ.get("BACKOFF_PROXY_BASE_DELAY", "2.0"))
FACTOR = 2.0
MAX_RETRIES = int(os.environ.get("BACKOFF_PROXY_MAX_RETRIES", "6"))
STORM_THRESHOLD_PER_MIN = 30   # spec: alarm if run-creation rate explodes

# Hop-by-hop headers must not be forwarded verbatim.
_HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate",
               "proxy-authorization", "te", "trailers",
               "transfer-encoding", "upgrade"}


class TargetState:
    """Shared state per proxy listener: offline flag + storm counters."""

    def __init__(self, target_url: str, probe_interval: float):
        self.target_url = target_url.rstrip("/")
        self.offline = False
        self.offline_since = None
        self.probe_interval = probe_interval
        self.lock = threading.Lock()
        # storm metrics: timestamps of requests in the last 60 s
        self.request_times = []
        self.stats = {"forwarded": 0, "retried": 0, "offline_rejects": 0,
                      "backoff_giveups": 0, "recoveries": 0}
        # Circuit-breaker: timestamp while one request's retry ladder is
        # active. Concurrent requests during an outage fail fast (503)
        # instead of each spawning their own retry ladder (thundering herd).
        self.ladder_active_since = None

    def record_request(self):
        now = time.time()
        with self.lock:
            self.request_times.append(now)
            self.request_times[:] = [t for t in self.request_times if now - t <= 60]
            rate = len(self.request_times)
        if rate > STORM_THRESHOLD_PER_MIN:
            print(f"[storm-metric] WARNING: request rate {rate}/min exceeds "
                  f"threshold {STORM_THRESHOLD_PER_MIN}/min — possible run "
                  f"storm during outage (#6596)", flush=True)
        return rate

    def set_offline(self, offline: bool):
        with self.lock:
            if offline and not self.offline:
                self.offline = True
                self.offline_since = time.time()
                print(f"[proxy] OFFLINE: target {self.target_url} unreachable "
                      f"— suspending forwarding, failing fast (503)", flush=True)
            elif not offline and self.offline:
                self.offline = False
                self.stats["recoveries"] += 1
                dur = time.time() - (self.offline_since or time.time())
                print(f"[proxy] RECOVERED: target {self.target_url} reachable "
                      f"again after {int(dur)}s — resuming forwarding "
                      f"(idempotent: no queued/duplicated requests)", flush=True)
                self.offline_since = None
        return self.offline

    def probe(self):
        """Background probe: if offline, check whether the target is back."""
        while True:
            time.sleep(self.probe_interval)
            if not self.offline:
                continue
            try:
                req = urllib.request.Request(self.target_url + "/__health",
                                             method="GET")
                urllib.request.urlopen(req, timeout=3).read(64)
                self.set_offline(False)
            except Exception:
                pass  # still offline; keep probing


def delay_for_attempt(attempt: int) -> float:
    """Exponential backoff with jitter: base * factor^attempt, +/-20%."""
    d = BASE_DELAY * (FACTOR ** attempt)
    jitter = d * random.uniform(-0.2, 0.2)
    return max(0.05, d + jitter)


def connect_error(exc: Exception) -> bool:
    """True only for connect-level (network) failures worth retrying."""
    if isinstance(exc, urllib.error.HTTPError):
        return False  # an HTTP response exists — never retry it
    if isinstance(exc, urllib.error.URLError):
        reason = getattr(exc, "reason", None)
        if isinstance(reason, ConnectionError) or "Connection" in type(reason).__name__:
            return True
        if isinstance(reason, OSError):
            return True  # ENOTFOUND / ECONNREFUSED / ETIMEDOUT surfaces here
        return True
    if isinstance(exc, (ConnectionError, OSError, TimeoutError)):
        return True
    return False


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "SisyphusBackoffProxy/1.0"
    state: TargetState = None   # injected per-server
    protocol_version = "HTTP/1.1"

    def _relay(self, method: str):
        st = self.state
        rate = st.record_request()

        if self.path == "/__health":
            body = json.dumps({"status": "ok", "offline": st.offline,
                               "target": st.target_url, "req_per_min": rate,
                               "stats": st.stats}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Offline suspension / circuit-breaker: fail fast, no upstream storm
        # (#6596). A request arriving while another request's retry ladder is
        # already running (or the target is offline) gets an immediate 503 —
        # only ONE ladder runs at a time per target.
        with st.lock:
            ladder_busy = st.ladder_active_since is not None
        if st.offline or ladder_busy:
            st.stats["offline_rejects"] += 1
            reason = ("offline" if st.offline
                      else "retry-ladder already active (circuit-breaker)")
            print(f"[proxy] {method} {self.path}: fast-fail 503 ({reason})",
                  flush=True)
            body = json.dumps({"error": "upstream unreachable — suspended "
                                        "(backoff proxy)",
                               "reason": reason,
                               "target": st.target_url,
                               "retry_after": int(st.probe_interval)}
                               ).encode()
            self.send_response(503)
            self.send_header("Retry-After", str(int(st.probe_interval)))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else None
        url = st.target_url + self.path
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in _HOP_BY_HOP
                   and k.lower() != "host"}

        attempt = 0
        while True:
            try:
                req = urllib.request.Request(url, data=payload,
                                             headers=headers, method=method)
                resp = urllib.request.urlopen(req, timeout=30)
                body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in _HOP_BY_HOP:
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                st.stats["forwarded"] += 1
                with st.lock:
                    st.ladder_active_since = None
                if attempt:
                    print(f"[proxy] {method} {self.path} succeeded on "
                          f"attempt {attempt + 1}", flush=True)
                return
            except urllib.error.HTTPError as exc:
                # Upstream responded with an HTTP error (e.g. 401, 404, 503).
                # Relay the upstream status and body — never retry, never mask.
                try:
                    body = exc.read()
                except Exception:
                    body = str(exc).encode()
                self.send_response(exc.code)
                self.send_header("Content-Type",
                                 exc.headers.get("Content-Type",
                                                 "application/json"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                print(f"[proxy] {method} {self.path}: upstream HTTP "
                      f"{exc.code} relayed", flush=True)
                return
            except Exception as exc:
                if not connect_error(exc) or attempt >= MAX_RETRIES:
                    # Upstream responded (HTTP-level) or retries exhausted:
                    # pass the failure through — never mask non-network errors.
                    if connect_error(exc):
                        st.stats["backoff_giveups"] += 1
                        print(f"[proxy] {method} {self.path}: giving up after "
                              f"{attempt + 1} attempts — {exc}", flush=True)
                        st.set_offline(True)
                        with st.lock:
                            st.ladder_active_since = None
                    else:
                        print(f"[proxy] {method} {self.path}: upstream error "
                              f"{exc!r}", flush=True)
                    try:
                        body = json.dumps({"error": str(exc)}).encode()
                        code = 502 if connect_error(exc) else 502
                        self.send_response(code)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    except Exception:
                        pass
                    return
                d = delay_for_attempt(attempt)
                attempt += 1
                with st.lock:
                    st.ladder_active_since = time.time()
                st.stats["retried"] += 1
                print(f"[proxy] {method} {self.path}: connect failure "
                      f"({exc!r}) — retry {attempt}/{MAX_RETRIES} in {d:.2f}s",
                      flush=True)
                time.sleep(d)

    def do_GET(self):
        self._relay("GET")

    def do_POST(self):
        self._relay("POST")

    def do_PUT(self):
        self._relay("PUT")

    def do_DELETE(self):
        self._relay("DELETE")

    def do_PATCH(self):
        self._relay("PATCH")

    def log_message(self, *args):  # default noisy per-request log off
        pass


def serve(listen: str, target: str, probe_interval: float):
    host, port = urlsplit(f"//{listen}").hostname, urlsplit(f"//{listen}").port
    state = TargetState(target, probe_interval)
    ProxyHandler.state = state
    server = ThreadingHTTPServer((host, port), ProxyHandler)
    threading.Thread(target=state.probe, daemon=True,
                     name="offline-probe").start()
    print(f"[proxy] listening on http://{host}:{port} -> {state.target_url} "
          f"(backoff base={BASE_DELAY}s factor={FACTOR} "
          f"max-retries={MAX_RETRIES} probe={probe_interval}s)", flush=True)
    server.serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--listen", required=True, help="host:port to bind")
    ap.add_argument("--target", required=True, help="upstream base URL")
    ap.add_argument("--probe-interval", type=float, default=5.0)
    args = ap.parse_args()
    serve(args.listen, args.target, args.probe_interval)


if __name__ == "__main__":
    main()
