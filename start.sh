#!/usr/bin/env bash
# start.sh — one-button startup for the Sisyphus stack (ADR-07).
#
#  1. Verifies .env and ports.env exist.
#  2. Starts the Host Launcher micro-API (:9000) in the background.
#  3. Runs `docker compose up -d` (Paperclip + PostgreSQL).
#  4. Prints the readiness banner.
#
# Usage: ./start.sh [--skip-compose]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$ROOT/execution-plane/scripts/launcher.py"
LAUNCHER_PORT="${LAUNCHER_PORT:-9000}"
LOG="$ROOT/storage/launcher.log"

[[ -f "$ROOT/.env" ]] || { echo "FATAL: $ROOT/.env missing (copy .env.example)" >&2; exit 1; }
[[ -f "$ROOT/execution-plane/scripts/ports.env" ]] || {
  echo "FATAL: $ROOT/execution-plane/scripts/ports.env missing (copy ports.env.example)" >&2; exit 1; }

# ── 1. Host Launcher (already running? idempotent) ─────────────────────────
if ss -ltn 2>/dev/null | grep -q ":${LAUNCHER_PORT} "; then
  echo "[start] launcher already listening on :${LAUNCHER_PORT}"
else
  echo "[start] starting Host Launcher on :${LAUNCHER_PORT} ..."
  mkdir -p "$ROOT/storage"
  nohup python3 "$LAUNCHER" --host "${LAUNCHER_HOST:-127.0.0.1}" --port "$LAUNCHER_PORT" \
    >> "$LOG" 2>&1 &
  echo "[start] launcher pid $! (log: $LOG)"
  # wait for readiness
  for _ in $(seq 1 20); do
    ss -ltn 2>/dev/null | grep -q ":${LAUNCHER_PORT} " && break
    sleep 0.5
  done
fi

# ── 2. Control Plane (Docker Compose) ─────────────────────────────────────
if [[ "${1:-}" != "--skip-compose" ]]; then
  if docker compose version >/dev/null 2>&1; then
    (cd "$ROOT" && docker compose up -d)
  elif command -v docker-compose >/dev/null 2>&1; then
    (cd "$ROOT" && docker-compose up -d)
  else
    echo "WARNING: docker compose plugin not installed —" \
         "start the Control Plane manually or: pacman -S docker-compose" >&2
  fi
fi

# ── 3. Readiness banner ───────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════"
echo "  Sisyphus stack starting"
echo "    Host Launcher : http://127.0.0.1:${LAUNCHER_PORT}  (/status)"
echo "    Paperclip UI  : http://localhost:3000"
echo "    Goose dev     : http://host.docker.internal:3284/acp"
echo "    Goose reviewer: http://host.docker.internal:3285/acp"
echo "    Hermes ceo    : http://host.docker.internal:8642"
echo "  Launch agents on demand:"
echo "    curl -X POST 'http://127.0.0.1:${LAUNCHER_PORT}/launch?profile=dev&engine=goose'"
echo "════════════════════════════════════════════════════════════"
