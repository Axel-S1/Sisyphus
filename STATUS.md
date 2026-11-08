# Project Status — Sisyphus (updated 2026-11-06)

Progress tracker for the 6-phase MVP plan — see
[`docs/phases/README.md`](docs/phases/README.md) and the architecture spec
[`docs/spec/architecture-spec.md`](docs/spec/architecture-spec.md) (v2.4).

| # | Phase | Status |
|---|-------|--------|
| 1 | Monorepo scaffolding | ✅ Done (`7fa1fda`, `52f138e`) |
| 2 | Execution plane daemons | ✅ Done (`d3c0c0a`, `1cc513a`) |
| 3 | Control plane (Paperclip) | ✅ Done (`c3224d2`, `67aba3f`, `de6a38a`) |
| 4 | Security mitigations | ⬜ Pending |
| 5 | Reliability watchdog | ⬜ Pending |
| 6 | E2E validation & Go/No-Go | ⬜ Pending |

## What is done

### Phase 1 — Monorepo scaffolding
- Full directory tree (control-plane, execution-plane, storage, docs).
- `.gitignore` with the spec-mandated lines (R8) + hygiene rules +
  `.gitkeep` negations + `storage/paperclip_pgdata/` + launcher logs.
- `.env.example` (distinct `API_SERVER_KEY` / `GOOSE_SERVER__SECRET_KEY` +
  Paperclip bootstrap secrets) and `ports.env.example` (ADR-06 registry).

### Phase 2 — Execution plane daemons
- `run.sh` / `run.ps1`: load `.env` + `ports.env`, inject `HERMES_HOME` +
  `GOOSE_PATH_ROOT` symmetrically (ADR-03, hard-fail), resolve profile port
  from the registry, exec the correct server command.
- Profile configs: `dev`/`reviewer` Goose (`GOOSE_MODE: smart_approve`,
  tracked `permission.yaml` policy), `ceo` Hermes (`SOUL.md`, `AGENTS.md`).
- systemd templates were removed — deprecated by ADR-07 (Host Launcher).

### Phase 3 — Control plane (Paperclip)
- **Host Launcher Micro-API (ADR-07)**: `launcher.py` (:9000, `/launch`,
  `/shutdown`, `/touch`, `/status`, 10-min idle watchdog with real-traffic
  liveness probe) + `start.sh`/`stop.sh` one-button scripts.
- **Real Paperclip in Docker**: `ghcr.io/paperclipai/paperclip:latest`
  (UI/API host :3000 → container :3100) + external PostgreSQL 16 with
  `DATABASE_URL`; Drizzle migrations applied at boot; health checks green.
- **adapters.json**: network-only adapter contract with real-schema mapping
  (`sessionKeyStrategy: 'run'` as the durable equivalent of the historical
  `persistSession:false`; hermes_local forbidden in-container per ADR-01).
- **Atomic connectivity suite**: `test_container_connectivity.sh`.
- In-container tests **all passed** (after `sudo ufw allow in on docker0`):
  goose dev + reviewer ACP handshakes with `X-Secret-Key`, 401 negative test,
  clean teardown via launcher endpoints.

## Verified facts (validated against installed builds)

- **Goose 1.56.0**: `goose serve --host 0.0.0.0 --port <p>` (env vars for
  host/port are ignored — CLI flags required); auth header **`X-Secret-Key`**
  (`Authorization: Bearer` → 401); ACP `initialize` needs an integer
  `protocolVersion`; `GOOSE_PATH_ROOT` fully redirects config/data/state;
  `GOOSE_MODE=smart_approve` valid; concurrent profiles had **zero
  cross-writes**.
- **Hermes v0.22.7 (re-verified live, 2026-11-06)**: the HTTP backend server
  is **`hermes serve --port <p> --host <h>`** ("JSON-RPC/WebSocket gateway
  the desktop app and remote clients connect to"). `hermes gateway` is
  messaging-platform management (Telegram/Discord/WhatsApp) — no `--port`;
  `hermes acp` is stdio-only. Non-loopback binds require Hermes's own auth
  provider (`--insecure` is a documented no-op).
- **Paperclip (ghcr.io/paperclipai/paperclip)**: serves :3100; external
  Postgres via `DATABASE_URL`; requires `BETTER_AUTH_SECRET`; migrations at
  boot; **no `persistSession` field** — the durable equivalent is
  `sessionKeyStrategy: 'run'`; no native Goose adapter (ACP route via goose
  serve is the contract); adapter secrets stored as Paperclip secret refs,
  not container env.
- **Networking**: host firewall must `allow in on docker0` for container→host
  traffic. Host Launcher binds **0.0.0.0:9000** (per ADR-07) with a
  **mandatory `X-Launcher-Secret`** header — container-originated triggers
  are the intended ADR-07 path.

## Pending / open items

- **Phase 4**: `permission.yaml` is tracked and enforced at the
  tool-name level; pattern rules still require the wrapper enforcement
  layer. The env-scrub is present in the installed Hermes build.
  **None of the acceptance criteria are verified yet**: the
  `/proc/<pid>/environ` smart_approve check, the negative permission tests,
  and the `execute_code` PYTHONPATH test must be executed and evidenced per
  `docs/phases/04-security-mitigations.md`.
- **Phase 5**: `watchdog-locks.sh` is implemented; its acceptance criteria
  are unverified. The #6596 backoff deliverable is to be implemented per
  `docs/phases/05-reliability-watchdog.md`.
- **Phase 6**: not started.
- **State sync (ADR-08)**: `setup-sync.sh` / `sync-export.sh` /
  `sync-import.sh` to be implemented per the ADR-08 contract (sanitized dumps
  keeping `account`, excluding the five plaintext-secret tables; symlink
  scaffold; SQLite + `*.sql.gz` hard-block). Spec v2.4 §ADR-08 documents the
  consistency model; acceptance criteria: clean clone → setup → export →
  second clone → import round-trip with no `*.db`, `*.sql.gz`, or plaintext
  secret content in the private repo.
- **Human step**: Paperclip one-time onboarding at <http://localhost:3000>
  (company + owner account), after which the smoke-ticket test can run.
