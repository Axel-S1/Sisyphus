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

# ── 3. Execution Plane daemons (repo-managed ONLY) ────────────────────────
# Teardown safety rule (Phase 3): NEVER a broad pkill — the operator's own
# desktop goose/hermes sessions also run `goose serve` / `hermes serve` and
# must survive. We only stop daemons whose environment carries this repo's
# HERMES_HOME / GOOSE_PATH_ROOT (i.e. spawned via run.sh / the launcher).
GPIDS="$(pgrep -f 'goose serve' 2>/dev/null || true)"
HPIDS="$(pgrep -f 'hermes (serve|gateway)' 2>/dev/null || true)"

is_repo_managed() {  # $1 = pid
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null \
    | grep -qE '^(HERMES_HOME|GOOSE_PATH_ROOT)='"$ROOT"'/storage/'
}

for p in $GPIDS $HPIDS; do
  if is_repo_managed "$p"; then
    echo "[stop] TERM repo-managed daemon pid $p"
    kill -TERM "$p" 2>/dev/null || true
  else
    echo "[stop] skipping pid $p (not repo-managed — operator session preserved)"
  fi
done
sleep 2
for p in $GPIDS $HPIDS; do
  if is_repo_managed "$p" 2>/dev/null; then
    kill -0 "$p" 2>/dev/null && { echo "[stop] KILL pid $p"; kill -KILL "$p" 2>/dev/null || true; }
  fi
done

echo "[stop] Sisyphus stack stopped."
