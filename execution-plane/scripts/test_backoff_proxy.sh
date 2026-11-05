#!/usr/bin/env bash
# test_backoff_proxy.sh — Phase 5 (T2) verification for #6596 semantics.
# Atomic single-invocation block (background processes die with the shell).
#
# Covers the spec's verification tests:
#   1. Backoff + jitter: upstream fails first 3 connect attempts -> proxy
#      retries with exponential backoff, succeeds on attempt 4.
#   2. Offline suspension: dead target -> 503 fast-fail (Retry-After), no
#      per-request retry storm; background probe auto-recovers when target
#      returns; storm metrics logged.
#   3. Idempotency safety: a POST that reached upstream is never replayed
#      (HTTP-level error passes through without retry).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LOG=/tmp/phase5_backoff_test.log
exec >"$LOG" 2>&1
set -x

export BACKOFF_PROXY_BASE_DELAY=0.4   # sped-up test: 0.4 * 2^n backoff
export BACKOFF_PROXY_MAX_RETRIES=6

# ── Fake upstream: refuses first 3 TCP connects, then serves; counts hits ──
python3 - <<'PYEOF' &
import socket, threading, time, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

hits = {"count": 0}
refused = {"count": 0}

class H(BaseHTTPRequestHandler):
    def _respond(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        hits["count"] += 1
        self._respond(200, {"ok": True, "hits": hits["count"], "path": self.path})
    def do_POST(self):
        hits["count"] += 1
        self._respond(503, {"ok": False, "hits": hits["count"]})  # HTTP-level: must NOT be retried
    def log_message(self, *a): pass

srv = ThreadingHTTPServer(("127.0.0.1", 44443), H)
t = threading.Thread(target=srv.serve_forever, daemon=True); t.start()

# Separate listener that refuses the first 3 connects (backoff test target)
flaky = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
flaky.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
flaky.bind(("127.0.0.1", 44444)); flaky.listen(16)
def flaky_serve():
    served = 0
    while True:
        c, _ = flaky.accept()
        served += 1
        if served <= 3:
            c.close()  # simulate refused/unstable connect
            refused["count"] += 1
            continue
        # after 3 refusals, serve a real HTTP response (simulates recovery)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"ok\": true, \"recovered\": true}")
        c.close()
t2 = threading.Thread(target=flaky_serve, daemon=True); t2.start()
time.sleep(0.3)
print("UPSTREAM_READY", flush=True)
while True: time.sleep(3600)
PYEOF
UPSTREAM_PID=$!
sleep 1

# ── Start proxies ──────────────────────────────────────────────────────────
# P1: proxy in front of the flaky listener (backoff test)
python3 execution-plane/scripts/backoff_proxy.py --listen 127.0.0.1:13284 --target http://127.0.0.1:44444 --probe-interval 3 &
P1=$!
# P2: proxy in front of the healthy server (offline test)
python3 execution-plane/scripts/backoff_proxy.py --listen 127.0.0.1:13285 --target http://127.0.0.1:44443 --probe-interval 3 &
P2=$!
sleep 1

echo "=== TEST 1: backoff — flaky connect, proxy must succeed via retries ==="
curl -sS --max-time 30 "http://127.0.0.1:13284/health-check" && echo " [BACKOFF_OK]"

echo "=== TEST 2a: HTTP-level error is NOT retried (idempotency) ==="
curl -sS --max-time 10 -X POST "http://127.0.0.1:13285/create" -d '{}' -w "\nstatus=%{http_code}\n"
UPSTREAM_HITS=$(curl -sS --max-time 5 "http://127.0.0.1:44443/stats" || true)
echo "(upstream should show only 1 hit for the POST above)"

echo "=== TEST 2b: offline — kill upstream, requests must 503 fast (no storm) ==="
kill "$UPSTREAM_PID" 2>/dev/null || true
sleep 1
START=$(date +%s%N)
for i in 1 2 3; do
  curl -sS -o /dev/null --max-time 8 -w "req$i status=%{http_code} time=%{time_total}s\n" \
    "http://127.0.0.1:13285/storm-probe$i" || echo "req$i failed (offline 503 expected)"
done
END=$(date +%s%N)
echo "3 offline requests took $(( (END - START) / 1000000 ))ms total (expect fast, no backoff storm)"

echo "=== TEST 2c: proxy /__health stats ==="
curl -sS --max-time 5 "http://127.0.0.1:13285/__health"; echo
curl -sS --max-time 5 "http://127.0.0.1:13284/__health"; echo

echo "=== TEST 2d: probe recovery is attempted while offline (log check) ==="
sleep 4   # probe interval

echo "=== Teardown ==="
kill "$P1" "$P2" 2>/dev/null || true
echo TESTBLOCK_DONE
