#!/usr/bin/env bash
# stop.sh — clean shutdown of the Sisyphus stack (ADR-07).
#
#  1. `docker compose down` (Paperclip + PostgreSQL).
#  2. Stops the Host Launcher micro-API.
#  3. Gracefully terminates any goose / hermes daemons still running
#     (launcher-managed or orphans).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Control Plane ───────────────────────────────────────────────────────
if docker compose version >/dev/null 2>&1; then
  (cd "$ROOT" && docker compose down --remove-orphans)
elif command -v docker-compose >/dev/null 2>&1; then
  (cd "$ROOT" && docker-compose down --remove-orphans)
else
  echo "WARNING: docker compose plugin not installed —" \
       "stop containers manually if any are running" >&2
fi

# ── 2. Host Launcher ──────────────────────────────────────────────────────
LPIDS="$(pgrep -f 'launcher\.py' 2>/dev/null || true)"
if [[ -n "$LPIDS" ]]; then
  echo "[stop] stopping Host Launcher: $LPIDS"
  pkill -TERM -f 'launcher\.py' 2>/dev/null || true
fi

# ── 3. Execution Plane daemons ────────────────────────────────────────────
GPIDS="$(pgrep -f 'goose serve' 2>/dev/null || true)"
HPIDS="$(pgrep -f 'hermes serve' 2>/dev/null || true)"
for p in $GPIDS $HPIDS; do
  echo "[stop] TERM daemon pid $p"
  kill -TERM "$p" 2>/dev/null || true
done
sleep 2
for p in $GPIDS $HPIDS; do
  kill -0 "$p" 2>/dev/null && { echo "[stop] KILL pid $p"; kill -KILL "$p" 2>/dev/null || true; }
done

echo "[stop] Sisyphus stack stopped."
