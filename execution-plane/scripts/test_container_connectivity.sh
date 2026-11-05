#!/usr/bin/env bash
# Phase 3 atomic connectivity test: container -> host daemons via host-gateway
# Single-invocation block: start launcher, spawn daemons, test from container, teardown.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LOG=/tmp/phase3_conn_test.log
exec >"$LOG" 2>&1
set -x

# --- load env ---
set -a
source .env 2>/dev/null || source .env.example
source execution-plane/scripts/ports.env
set +a
SECRET="$GOOSE_SERVER__SECRET_KEY"
DEV_PORT="${GOOSE_PORT_DEV:-3284}"
REV_PORT="${GOOSE_PORT_REVIEWER:-3285}"
LAUNCH_PORT=9000

# --- start launcher (background, dies with this shell = self-cleanup) ---
python3 execution-plane/scripts/launcher.py --host 127.0.0.1 --port "$LAUNCH_PORT" \
  --idle-timeout 600 --poll-interval 3600 &
LAUNCHER_PID=$!
sleep 2

# --- launcher status: confirm up ---
curl -sS --max-time 5 "http://127.0.0.1:$LAUNCH_PORT/status" || echo "LAUNCHER_DOWN"

# --- launch goose dev + reviewer profiles via launcher ---
curl -sS -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" --max-time 20 "http://127.0.0.1:$LAUNCH_PORT/launch?profile=dev&engine=goose" || echo "LAUNCH_DEV_FAIL"
curl -sS -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" --max-time 20 "http://127.0.0.1:$LAUNCH_PORT/launch?profile=reviewer&engine=goose" || echo "LAUNCH_REV_FAIL"
sleep 4
curl -sS --max-time 5 "http://127.0.0.1:$LAUNCH_PORT/status" || echo "LAUNCHER_STATUS_FAIL"

# --- host-local sanity: daemons listening ---
echo "--- host-local checks ---"
curl -sS -o /dev/null -w "host->dev:%{http_code}\n" --max-time 5 "http://127.0.0.1:$DEV_PORT/acp" || true
curl -sS -o /dev/null -w "host->rev:%{http_code}\n" --max-time 5 "http://127.0.0.1:$REV_PORT/acp" || true

# --- container -> host tests via host.docker.internal ---
echo "--- container checks ---"
docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl:latest \
  -sS -o /dev/null -w "ctr->dev:%{http_code}\n" --max-time 8 "http://host.docker.internal:$DEV_PORT/acp" || echo "CTR_DEV_FAIL"

docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl:latest \
  -sS -o /dev/null -w "ctr->rev:%{http_code}\n" --max-time 8 "http://host.docker.internal:$REV_PORT/acp" || echo "CTR_REV_FAIL"

# --- ACP initialize handshake from container (dev) with secret ---
echo "--- ACP handshake (dev) ---"
docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl:latest \
  -sS --max-time 8 \
  -H "Content-Type: application/json" \
  -H "X-Secret-Key: $SECRET" \
  -X POST "http://host.docker.internal:$DEV_PORT/acp" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  && echo || echo "ACP_INIT_FAIL"

# --- ACP handshake (reviewer) ---
echo "--- ACP handshake (reviewer) ---"
docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl:latest \
  -sS --max-time 8 \
  -H "Content-Type: application/json" \
  -H "X-Secret-Key: $SECRET" \
  -X POST "http://host.docker.internal:$REV_PORT/acp" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  && echo || echo "ACP_INIT_REV_FAIL"

# --- negative auth test: no secret -> expect 401 ---
echo "--- negative auth (expect 401) ---"
docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl:latest \
  -sS -o /dev/null -w "no-secret:%{http_code}\n" --max-time 8 \
  -X POST "http://host.docker.internal:$DEV_PORT/acp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}' || echo "NEG_TEST_FAIL"

# --- teardown: shut down profiles, launcher dies with shell anyway ---
# Teardown via launcher only — NEVER pkill goose broadly:
# the Goose Desktop session also runs `goose serve` and must not be killed.
curl -sS -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" --max-time 10 "http://127.0.0.1:$LAUNCH_PORT/shutdown?profile=dev" || true
curl -sS -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" --max-time 10 "http://127.0.0.1:$LAUNCH_PORT/shutdown?profile=reviewer" || true
kill "$LAUNCHER_PID" 2>/dev/null || true

echo "=== TEST BLOCK COMPLETE ==="
