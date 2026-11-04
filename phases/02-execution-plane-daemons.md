# Phase 2/6 — Execution Plane Daemons (Hermes gateway + goose serve)

> Spec reference: §2.3, §2.4, ADR-01 (HTTP/ACP gateway), ADR-03 (symmetric env
> injection), ADR-06 (port registry), §5.3 (systemd unit), §5.6 (`run.sh`).
> Depends on: Phase 1 (monorepo tree, `ports.env.example`).

## Objective

Stand up the **Execution Plane** on the native host: two resident HTTP
daemons (Hermes gateway :8642, Goose `goose serve` HTTP/WS ACP) kept alive by
systemd, plus bootstrap wrappers with symmetric `HERMES_HOME` +
`GOOSE_PATH_ROOT` injection and **hard failure if either is missing**.

## Critical facts (memorize — this is Risk R9)

- The network server is **`goose serve`** — HTTP/WebSocket ACP (JSON-RPC 2.0)
  at endpoint `/acp`, defaults `127.0.0.1:3284`, auth header via
  `GOOSE_SERVER__SECRET_KEY`.
- **`goose acp` is a different command** — stdio-only, for editors like Zed.
  It cannot accept network connections. A systemd unit running `goose acp`
  produces a daemon listening on nothing, silently.
- Default bind is `127.0.0.1`, which **silently refuses** traffic from
  `host.docker.internal`. For this architecture you must set
  `GOOSE_SERVER__HOST=0.0.0.0`.
- Goose **ignores** `HERMES_HOME` (Rust/XDG paths). Per-profile isolation
  strictly requires `GOOSE_PATH_ROOT` (ADR-03). Without it, concurrent
  profiles overwrite each other's `~/.config/goose/config.yaml` and
  `sessions.db` (Risk R4).
- MVP security mode: `GOOSE_MODE=smart_approve` (never `auto` — Risk R7).

## Prerequisites

- Phase 1 tree exists; `ports.env` created from the example with real values.
- Installed on the host: `hermes` (Hermes CLI), `goose` (Goose CLI), and a
  process manager. On macOS use launchd equivalents or keep `run.sh`
  foreground as fallback; the reference platform here is systemd (Linux).
- Cloud LLM keys present in `.env` (ANTHROPIC_API_KEY / OPENAI_API_KEY).

## Tasks

### 1. Write `execution-plane/scripts/run.sh` (POSIX bootstrap)

```bash
#!/usr/bin/env bash
set -euo pipefail
PROFILE="${1:?usage: run.sh <profile> [hermes|goose]}"
ENGINE="${2:-auto}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

git -C "$ROOT" pull --rebase || true
set -a; source "$ROOT/.env"; set +a
# ADR-06: load per-profile ports
set -a; source "$ROOT/execution-plane/scripts/ports.env"; set +a

export HERMES_HOME="$ROOT/storage/hermes_data/agent_$PROFILE"
export GOOSE_PATH_ROOT="$ROOT/storage/goose_data/agent_$PROFILE"
mkdir -p "$HERMES_HOME" "$GOOSE_PATH_ROOT"
# ADR-03: hard failure if either variable missing (defense in depth)
[[ -n "${HERMES_HOME:-}" && -n "${GOOSE_PATH_ROOT:-}" ]] || {
  echo "FATAL: HERMES_HOME / GOOSE_PATH_ROOT not set" >&2; exit 1; }

case "$ENGINE" in
  hermes)
    export API_SERVER_KEY="${API_SERVER_KEY:?API_SERVER_KEY required}"
    exec hermes gateway run --port "${HERMES_PORT_CEo:?HERMES_PORT_CEo required}" ;;
  goose)
    # HTTP/WS ACP server — NOT `goose acp` (stdio-only, editor clients)
    export GOOSE_MODE="${GOOSE_MODE:-smart_approve}"
    export GOOSE_SERVER__HOST="${GOOSE_SERVER__HOST:-0.0.0.0}"
    export GOOSE_SERVER__PORT="${GOOSE_SERVER__PORT:?GOOSE_SERVER__PORT required (ADR-06)}"
    export GOOSE_SERVER__SECRET_KEY="${GOOSE_SERVER__SECRET_KEY:?secret required}"
    exec goose serve ;;
  auto)
    if [[ -d "$ROOT/execution-plane/profiles/$PROFILE/goose_config" ]]; then
      exec "$0" "$PROFILE" goose
    else
      exec "$0" "$PROFILE" hermes
    fi ;;
  *) echo "unknown engine: $ENGINE" >&2; exit 1 ;;
esac
```

Notes:
- ⚠️ The port env-var names (`HERMES_PORT_CEo`, `GOOSE_SERVER__PORT`,
  `GOOSE_SERVER__HOST`, `GOOSE_SERVER__SECRET_KEY`, `GOOSE_MODE`) must be
  validated against the **installed** Hermes/Goose builds' actual config
  surface (`hermes --help`, `goose serve --help`, Goose `config.yaml`
  schema). Names flagged in the spec as illustrative must be adapted; the
  durable contract is: HTTP target URLs + distinct secrets + one port per
  profile.
- Wire `GOOSE_PATH_ROOT` per profile for Goose; for Hermes also ensure the
  Hermes gateway serves the profile's `HERMES_HOME` (check the installed
  Hermes config mechanism; profile dirs are
  `execution-plane/profiles/<name>/hermes_config/` and `goose_config/`).
- Keep ADR-04 in mind for Phase 4: any SQLite db under `storage/` reachable
  via a Docker mount must use `journal_mode: delete` — configure Goose/Hermes
  session DBs accordingly if their config allows it now, otherwise Phase 4.

### 2. Write `execution-plane/scripts/run.ps1` (Windows bootstrap)

Same logic in PowerShell: `git pull --rebase` (tolerate failure), load
`.env` and `ports.env`, set `$env:HERMES_HOME` and `$env:GOOSE_PATH_ROOT`
(both, symmetric), then `hermes gateway run` or `goose serve` with
`GOOSE_SERVER__HOST`/`GOOSE_SERVER__PORT` set. Hard-fail when variables are
missing.

### 3. Write systemd units — `execution-plane/scripts/systemd/`

> ⚠️ **DEPRECATED (2026-11-04, ADR-07).** The persistent systemd daemons were
> superseded by the **Host Launcher Micro-API** (`execution-plane/scripts/launcher.py`,
> port 9000) introduced by ADR-07: daemons are now spawned on demand via
> `run.sh`/`run.ps1` and terminated after a 10-minute idle timeout, instead of
> running continuously under systemd. The systemd templates below are kept for
> historical reference only — **do not install them**. Phase 3 Task 0 builds the
> launcher; its auto-restart (relaunch on demand) replaces `Restart=on-failure`.

`goose-serve@.service` (template, one instance per profile):

```ini
# /etc/systemd/system/goose-serve@.service
# One instance per profile: systemctl start goose-serve@dev
[Unit]
Description=Goose ACP-over-HTTP server (profile %i)
After=network.target

[Service]
Type=simple
User=%i
WorkingDirectory=/home/%i/local-first-agents
EnvironmentFile=/home/%i/local-first-agents/execution-plane/scripts/ports.env
Environment=GOOSE_PATH_ROOT=/home/%i/local-first-agents/storage/goose_data/agent_%i
Environment=GOOSE_MODE=smart_approve
# HTTP/WS ACP server — NOT `goose acp` (stdio-only, editor clients)
Environment=GOOSE_SERVER__HOST=0.0.0.0
# Per-profile port + secret via per-instance drop-in:
#   systemctl edit goose-serve@dev  →  [Service]
#     Environment=GOOSE_SERVER__PORT=3284
#     Environment=GOOSE_SERVER__SECRET_KEY=<from .env / protected file>
# (In production the secret MUST live in a protected EnvironmentFile, never inline.)
ExecStart=/usr/local/bin/goose serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Also write `hermes-gateway@.service` (same shape):
`Environment=HERMES_HOME=.../storage/hermes_data/agent_%i`, `API_SERVER_KEY`
loaded from a **protected** `EnvironmentFile=` (never inline), ExecStart
`/usr/local/bin/hermes gateway run` with the profile port from the ADR-06
registry.

Adjust `User=`/paths to the actual machine (do not hardcode personal
usernames without checking). Provide an install snippet:
`cp unit → /etc/systemd/system/ && systemctl daemon-reload`.

### 4. Profile config files

For each profile ensure the config dirs from Phase 1 contain at minimum:

- `profiles/dev/goose_config/`: the Goose profile config declaring
  `GOOSE_MODE=smart_approve`, and (if supported by the installed build)
  permission rules — full `tool_permissions.json` content arrives in
  Phase 4; put a minimal default now.
- `profiles/ceo/hermes_config/`: minimal Hermes config (SOUL.md /
  AGENTS.md placeholders are enough at MVP).

### 5. Smoke tests (from the **host**)

```bash
# Ports listening?
ss -ltnp | grep -E '8642|3284'

# Hermes gateway auth-protected?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8642/   # expect non-200 without key

# goose serve ACP handshake (JSON-RPC 2.0 initialize)
curl -s http://127.0.0.1:3284/acp \
  -H "Authorization: Bearer $GOOSE_SERVER__SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

(Adapt request shape to the installed ACP version if the exact schema
differs; the goal is: HTTP endpoint answers an `initialize` handshake.)

## Acceptance criteria

- [ ] `run.sh dev goose` (or the systemd unit) starts `goose serve` bound to
      `0.0.0.0:<profile port>` — verify with `ss -ltnp`, **not** `127.0.0.1`.
- [ ] `/acp` answers a JSON-RPC 2.0 `initialize` handshake with the secret;
      refuses without the secret.
- [ ] `run.sh ceo hermes` starts the gateway on the registered port,
      auth-protected by `API_SERVER_KEY`.
- [ ] Two Goose profiles (`dev` :3284, `reviewer` :3285) run **concurrently**
      with distinct `GOOSE_PATH_ROOT`s; each writes its `sessions.db` /
      config only inside its own `storage/goose_data/agent_<profile>/` —
      check timestamps/inode churn: **zero cross-writes** (collision test,
      spec §8). Run with plain `GOOSE_PATH_ROOT` unset in a throwaway shell
      to confirm profiles do *not* touch `~/.config/goose/`.
- [ ] `run.sh` hard-fails when `GOOSE_PATH_ROOT`/`HERMES_HOME` cannot be set.
- [x] ~~systemd units installed, `daemon-reload` done, services auto-restart on
      failure (`Restart=on-failure`)~~ — **DEPRECATED by ADR-07**: persistent
      systemd daemons are obsolete; the Host Launcher Micro-API (Phase 3
      Task 0) provides on-demand spawn + idle-timeout teardown instead.
      Daemons run via `run.sh`/`run.ps1` (validated by the handshake and
      collision tests above).
- [ ] No daemon was ever started with `goose acp`.

## Common pitfalls

- Running `goose acp` instead of `goose serve` → daemon listens on nothing
  (silent; caught only by the curl handshake test — never skip it).
- Leaving default `127.0.0.1` bind → works from host, dead from container.
- Testing the two-profile collision only sequentially — it must be
  **concurrent**.
- Secret inlined in the unit file instead of a protected EnvironmentFile.

## Outputs for next phase

Phase 3 (Control Plane) points Paperclip's adapters at
`http://host.docker.internal:<ports>` from this phase; record the actual
ports/URLs in the final summary.
