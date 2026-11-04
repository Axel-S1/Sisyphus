# Phase 3/6 — Control Plane (Paperclip in Docker)

> Spec reference: §2.2, ADR-01 (network IPC only), ADR-05 (#1160:
> `persistSession: false`), ADR-06 (per-profile adapter URLs), §5.2
> (docker-compose).
> Depends on: Phases 1–2 (repo tree + running host daemons on known ports).

## Objective

Dockerize the Control Plane (Paperclip) with PostgreSQL + Drizzle ORM, and
wire its adapters **exclusively over HTTP** to the Execution Plane daemons:
`hermes_gateway` → Hermes, and a REST/ACP client → `goose serve`. The
`hermes_local` adapter is **forbidden** inside the container (it can only
spawn within its own namespace).

## Prerequisites

- Phases 1–2 done; host daemons answer on their registered ports.
- Docker (or Podman) available. On Linux, `host.docker.internal` must be
  mapped via `extra_hosts: ["host.docker.internal:host-gateway"]`.

## Tasks

### Task 0 — Host Launcher Micro-API & One-Button Startup (ADR-07)

### Objective
Create a lightweight, cross-platform host script to start/stop agent daemons dynamically on demand and provide single-command startup for the entire infrastructure.

### Deliverables
1. `execution-plane/scripts/launcher.py` (or PowerShell equivalent):
   - Listens on `http://127.0.0.1:9000`.
   - Endpoint `POST /launch?profile=<profile>&engine=<goose|hermes>`: Spawns the daemon via `run.sh` / `run.ps1` if not already running on its registered port (ADR-06).
   - Endpoint `POST /shutdown?profile=<profile>`: Gracefully terminates the specified daemon.
   - Idle Watchdog: Monitors port traffic; kills the subprocess after 10 minutes of zero requests to free host RAM.
2. Root Startup Scripts:
   - `start.sh` / `start.ps1`:
     1. Verifies `.env` and `ports.env`.
     2. Launches `launcher.py` in the background on the host.
     3. Runs `docker compose up -d` to bring up Paperclip + PostgreSQL.
     4. Prints readiness banner (`http://localhost:3000`).
   - `stop.sh` / `stop.ps1`:
     1. Runs `docker compose down`.
     2. Kills the host launcher and any active `goose` / `hermes` processes cleanly.

> ⚠️ Bind check (Risk R9 class): if the launcher must be triggered from inside the Paperclip container, `127.0.0.1:9000` silently refuses `host.docker.internal` traffic — bind `0.0.0.0` and require a secret header in that case.

### 1. Write `docker-compose.yml`

```yaml
version: "3.8"
services:
  paperclip:
    image: paperclip/orchestrator:latest
    container_name: paperclip_control_plane
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - STORAGE_PATH=/app/storage
      # Execution Plane targets via the gateway — NEVER local spawning.
      # NOTE: env var names below are illustrative; the authoritative config
      # surface is control-plane/paperclip/config/adapters.json (verify
      # against Paperclip's actual adapter schema — ADR-06 schema caution).
      - HERMES_GATEWAY_URL=http://host.docker.internal:8642
      - GOOSE_ACP_URL=http://host.docker.internal:3284/acp
      - API_SERVER_KEY=${API_SERVER_KEY}
      - GOOSE_SERVER__SECRET_KEY=${GOOSE_SERVER__SECRET_KEY}
    extra_hosts:
      - "host.docker.internal:host-gateway"   # required on Linux
    volumes:
      - ./storage/paperclip_data:/app/storage
      - ./control-plane/paperclip/config:/app/config
      - ./execution-plane/workspace:/app/workspace
  # PostgreSQL: external service or dedicated volume (spec §2.2)
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      - POSTGRES_USER=paperclip
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?set in .env}
      - POSTGRES_DB=paperclip
    volumes:
      - ./storage/paperclip_pgdata:/var/lib/postgresql/data
```

Add `POSTGRES_PASSWORD=` to `.env` and `.env.example` (and keep `.env`
ignored). If the real Paperclip deployment prescribes a different image/
compose layout (check its repo/docs — e.g. `doc/SPEC-implementation.md`),
adapt; the durable contract is: no local spawning, network adapters, bind
mounts, external PostgreSQL.

### 2. Configure Drizzle ORM

Set up the Paperclip persistence layer with Drizzle against the `postgres`
service (connection string from env). Create the core tables Paperclip
needs — at minimum `tickets`, `runs` (with `checkout_run_id`,
`started_at`, `finished_at`, `last_activity_at`, `status`, `error` —
⚠️ column names in spec §5.4 are illustrative; align with the real Drizzle
schema). Run migrations; record the schema location.

### 3. Write `control-plane/paperclip/config/adapters.json`

- Adapter 1: `hermes_gateway` → `http://host.docker.internal:8642`, auth
  `API_SERVER_KEY`.
- Adapter 2: ACP/REST client for Goose → `http://host.docker.internal:3284/acp`,
  auth `GOOSE_SERVER__SECRET_KEY`.
- **ADR-05 / #1160:** set `persistSession: false` on the Hermes adapter
  config until an upstream fix validates the session-ID regex
  (`^\d{8}_\d{6}_[a-zA-Z0-9]+$` is too permissive; a corrupted ID persisted
  then `--resume` crashes → infinite 2-second-run loop).
- ⚠️ ADR-06: verify the actual adapters.json schema against the installed
  Paperclip before finalizing field names. The URLs, secrets and
  `persistSession:false` are the durable parts.

### 4. Connectivity tests from **inside the container**

This is the Phase-1 Go/No-Go heart (spec §8). After `docker compose up -d`:

```bash
# Hermes reachable from inside the container, with auth
docker exec paperclip_control_plane curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $API_SERVER_KEY" http://host.docker.internal:8642/

# goose serve /acp handshake from inside the container
docker exec paperclip_control_plane curl -s \
  -H "Authorization: Bearer $GOOSE_SERVER__SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  http://host.docker.internal:3284/acp
```

If these time out: the bind is localhost or the wrong binary is running —
go back to Phase 2 (R9).

## Acceptance criteria

- [ ] `docker compose up -d` brings up Paperclip + PostgreSQL; both healthy.
- [ ] Paperclip web/API on :3000 responds.
- [ ] From inside the container: Hermes endpoint answers (with key), Goose
      `/acp` answers an `initialize` handshake (with secret).
- [ ] From inside the container: **without** the secret, Goose refuses
      (negative auth test).
- [ ] Drizzle migrations applied; `tickets`/`runs` tables exist.
- [ ] `adapters.json` contains only network adapters (no `hermes_local`)
      and `persistSession: false` for Hermes.
- [ ] Paperclip can create a task via UI/API (a smoke ticket) without
      adapter errors.

## Common pitfalls

- Testing connectivity from the host instead of **inside** the container —
  the failure mode (localhost bind) only manifests cross-boundary.
- Forgetting `extra_hosts` on Linux → `host.docker.internal` unresolvable.
- Leaving `persistSession: true` (or absent) → Risk R2 infinite loop.
- Configuring `hermes_local` "because it's simpler" → forbidden by ADR-01.

## Outputs for next phase

Phase 4 hardens security on the running daemons; keep the container running
for the negative permission tests.
