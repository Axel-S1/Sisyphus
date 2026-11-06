#!/usr/bin/env bash
# run.sh — Execution Plane bootstrap (hermes serve / goose serve).
# Spec: §2.3, §2.4, ADR-01, ADR-03 (symmetric HERMES_HOME + GOOSE_PATH_ROOT),
# ADR-06 (port registry), §5.6. One server per profile, one port per profile.
#
# Usage: run.sh <profile> [hermes|goose|auto]
#   ./run.sh ceo hermes      # hermes serve    (port from ports.env)
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
# config.yaml AND permission.yaml are seeded (permission.yaml is the tracked
# tool-level policy source of truth — see the profile file's header).
GOOSE_CFG_SRC="$ROOT/execution-plane/profiles/$PROFILE/goose_config"
HERMES_CFG_SRC="$ROOT/execution-plane/profiles/$PROFILE/hermes_config"
if [[ -d "$GOOSE_CFG_SRC" ]] && compgen -G "$GOOSE_CFG_SRC/*" >/dev/null; then
  mkdir -p "$GOOSE_PATH_ROOT/config"
  if [[ ! -f "$GOOSE_PATH_ROOT/config/config.yaml" ]]; then
    cp "$GOOSE_CFG_SRC"/config.yaml "$GOOSE_PATH_ROOT/config/config.yaml"
  fi
  if [[ -f "$GOOSE_CFG_SRC/permission.yaml" && ! -f "$GOOSE_PATH_ROOT/config/permission.yaml" ]]; then
    cp "$GOOSE_CFG_SRC/permission.yaml" "$GOOSE_PATH_ROOT/config/permission.yaml"
  fi
fi
if [[ -d "$HERMES_CFG_SRC" ]] && compgen -G "$HERMES_CFG_SRC/*" >/dev/null; then
  for f in "$HERMES_CFG_SRC"/*; do
    [[ -e "$HERMES_HOME/$(basename "$f")" ]] || cp "$f" "$HERMES_HOME/"
  done
fi

# ── Phase 4 (T4): Enforce SQLite journal_mode=delete for all profiles ───
# Run before daemon startup to guarantee DB journal modes are compliant
# with the Sisyphus security and stability requirements (CVE-2026-9368).
bash "$ROOT/execution-plane/scripts/ensure-sqlite-modes.sh"

case "$ENGINE" in
  hermes)
    command -v hermes >/dev/null 2>&1 || {
      echo "FATAL: 'hermes' binary not found on PATH (Execution Plane requires it)" >&2; exit 127; }
    # Hermes's HTTP backend server is `hermes serve` — live-verified against
    # the installed build (2026-11-06): `hermes serve --help` describes it as
    # "the JSON-RPC/WebSocket gateway the desktop app and remote clients
    # connect to", with --port/--host flags. `hermes gateway` is
    # messaging-platform management (Telegram/Discord/WhatsApp) with NO
    # --port — never use it as the network daemon (Risk R9). The earlier
    # "gateway is the /v1/runs backend" claim in an uncommitted draft was
    # WRONG and is reverted to the spec-verified command.
    # Non-loopback binds require Hermes's own auth provider (password/OAuth;
    # --insecure is a documented no-op). API_SERVER_KEY / HERMES_API_KEY stay
    # exported (either name accepted) for adapter credential wiring, but are
    # optional here — the auth provider is the real binding gate.
    export API_SERVER_KEY="${API_SERVER_KEY:-${HERMES_API_KEY:-}}"
    export API_SERVER_PORT="$(port_from_registry "$PROFILE" HERMES_PORT)"
    export API_SERVER_HOST="0.0.0.0"
    exec hermes serve --port "$API_SERVER_PORT" --host "$API_SERVER_HOST" ;;
  goose)
    command -v goose >/dev/null 2>&1 || {
      echo "FATAL: 'goose' binary not found on PATH (Execution Plane requires it)" >&2; exit 127; }
    export GOOSE_MODE="${GOOSE_MODE:-smart_approve}"   # MVP: never auto (Risk R7)
    export GOOSE_SERVER__HOST="${GOOSE_SERVER__HOST:-0.0.0.0}"  # must accept host.docker.internal
    export GOOSE_SERVER__PORT="$(port_from_registry "$PROFILE" GOOSE_PORT)"
    export GOOSE_SERVER__SECRET_KEY="${GOOSE_SERVER__SECRET_KEY:?GOOSE_SERVER__SECRET_KEY required}"
    # Profile policy: goose 1.56.0 reads permission.yaml from the global
    # ~/.config/goose (no GOOSE_CONFIG_DIR override exists in the binary).
    # GOOSE_ADDITIONAL_CONFIG_FILES (verified present in the binary's
    # config-resolution strings) loads the profile's own policy on top, so the
    # dev/reviewer daemons are gated by their profile policy, not the desktop's.
    export GOOSE_ADDITIONAL_CONFIG_FILES="${GOOSE_PATH_ROOT}/config/permission.yaml"
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
