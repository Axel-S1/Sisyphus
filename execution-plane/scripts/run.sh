#!/usr/bin/env bash
# run.sh — Execution Plane bootstrap (Hermes gateway / goose serve).
# Spec: §2.3, §2.4, ADR-01, ADR-03 (symmetric HERMES_HOME + GOOSE_PATH_ROOT),
# ADR-06 (port registry), §5.6. One server per profile, one port per profile.
#
# Usage: run.sh <profile> [hermes|goose|auto]
#   ./run.sh ceo hermes      # Hermes gateway  (port from ports.env)
#   ./run.sh dev goose       # goose serve     (HTTP/WS ACP, port from ports.env)
set -euo pipefail

PROFILE="${1:?usage: run.sh <profile> [hermes|goose]}"
ENGINE="${2:-auto}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Tolerate network problems on an offline host (spec §5.6).
git -C "$ROOT" pull --rebase >/dev/null 2>&1 || true

# ── Load secrets (.env) and the ADR-06 port registry (ports.env) ────────
[[ -f "$ROOT/.env" ]] || { echo "FATAL: $ROOT/.env missing (copy .env.example)" >&2; exit 1; }
[[ -f "$ROOT/execution-plane/scripts/ports.env" ]] || {
  echo "FATAL: $ROOT/execution-plane/scripts/ports.env missing (copy ports.env.example)" >&2; exit 1; }
set -a; source "$ROOT/.env"; set +a
set -a; source "$ROOT/execution-plane/scripts/ports.env"; set +a

# ── ADR-03: symmetric per-profile injection — BOTH vars, hard failure ──
export HERMES_HOME="$ROOT/storage/hermes_data/agent_$PROFILE"
export GOOSE_PATH_ROOT="$ROOT/storage/goose_data/agent_$PROFILE"
mkdir -p "$HERMES_HOME" "$GOOSE_PATH_ROOT"
[[ -n "${HERMES_HOME:-}" && -n "${GOOSE_PATH_ROOT:-}" ]] || {
  echo "FATAL: HERMES_HOME / GOOSE_PATH_ROOT not set" >&2; exit 1; }

# ── ADR-06 port lookup (exact registry names: HERMES_PORT_CEo, GOOSE_PORT_DEV, …)
port_from_registry() {  # $1 = profile, $2 = var prefix ("HERMES_PORT"|"GOOSE_PORT")
  local profile="$1" prefix="$2" var val
  case "$profile" in
    ceo) var="${prefix}_CEo" ;;          # registry name per phase-1 template
    *)   var="${prefix}_${profile^^}" ;;
  esac
  val="${!var:-}"
  [[ -n "$val" ]] || { echo "FATAL: $var required (ADR-06 port registry)" >&2; exit 1; }
  printf '%s' "$val"
}

# Seed the profile config into the engine's isolated root (never overwrite).
GOOSE_CFG_SRC="$ROOT/execution-plane/profiles/$PROFILE/goose_config"
HERMES_CFG_SRC="$ROOT/execution-plane/profiles/$PROFILE/hermes_config"
if [[ -d "$GOOSE_CFG_SRC" ]] && compgen -G "$GOOSE_CFG_SRC/*" >/dev/null; then
  mkdir -p "$GOOSE_PATH_ROOT/config"
  if [[ ! -f "$GOOSE_PATH_ROOT/config/config.yaml" ]]; then
    cp "$GOOSE_CFG_SRC"/config.yaml "$GOOSE_PATH_ROOT/config/config.yaml"
  fi
fi
if [[ -d "$HERMES_CFG_SRC" ]] && compgen -G "$HERMES_CFG_SRC/*" >/dev/null; then
  for f in "$HERMES_CFG_SRC"/*; do
    [[ -e "$HERMES_HOME/$(basename "$f")" ]] || cp "$f" "$HERMES_HOME/"
  done
fi

case "$ENGINE" in
  hermes)
    command -v hermes >/dev/null 2>&1 || {
      echo "FATAL: 'hermes' binary not found on PATH (Execution Plane requires it)" >&2; exit 127; }
    export API_SERVER_KEY="${API_SERVER_KEY:?API_SERVER_KEY required (Hermes gateway auth)}"
    exec hermes gateway run --port "$(port_from_registry "$PROFILE" HERMES_PORT)" ;;
  goose)
    command -v goose >/dev/null 2>&1 || {
      echo "FATAL: 'goose' binary not found on PATH (Execution Plane requires it)" >&2; exit 127; }
    export GOOSE_MODE="${GOOSE_MODE:-smart_approve}"   # MVP: never auto (Risk R7)
    export GOOSE_SERVER__HOST="${GOOSE_SERVER__HOST:-0.0.0.0}"  # must accept host.docker.internal
    export GOOSE_SERVER__PORT="$(port_from_registry "$PROFILE" GOOSE_PORT)"
    export GOOSE_SERVER__SECRET_KEY="${GOOSE_SERVER__SECRET_KEY:?GOOSE_SERVER__SECRET_KEY required}"
    # HTTP/WS ACP server — NOT `goose acp` (stdio-only, editor clients; Risk R9).
    # --host/--port are passed as CLI flags (validated against installed build;
    # goose 1.56.0 does not honour GOOSE_SERVER__HOST/PORT env vars).
    exec goose serve --host "$GOOSE_SERVER__HOST" --port "$GOOSE_SERVER__PORT" ;;
  auto)
    if [[ -d "$ROOT/execution-plane/profiles/$PROFILE/goose_config" ]]; then
      exec "$0" "$PROFILE" goose
    else
      exec "$0" "$PROFILE" hermes
    fi ;;
  *) echo "unknown engine: $ENGINE" >&2; exit 1 ;;
esac
