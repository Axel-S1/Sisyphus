# Project Status — Sisyphus (updated 2026-11-08)

Progress tracker for the 6-phase MVP plan — see
[`docs/phases/README.md`](docs/phases/README.md) and the architecture spec
[`docs/spec/architecture-spec.md`](docs/spec/architecture-spec.md) (v2.4).

| # | Phase | Status |
|---|-------|--------|
| 1 | Monorepo scaffolding | ✅ Done (`7fa1fda`, `52f138e`) |
| 2 | Execution plane daemons | ✅ Done (`d3c0c0a`, `1cc513a`) |
| 3 | Control plane (Paperclip) | ✅ Done (`c3224d2`, `67aba3f`, `de6a38a`) |
| + | **State sync (ADR-08 addendum)** | ✅ Done (`c8879c0`, `cfde19f`; **clean-slate E2E validated 2026-11-08**) |
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
- **Atomic connectivity suite**: `test_container_connectivity.sh`
  (self-quieting: full output goes to `/tmp/phase3_conn_test.log`).
- In-container tests **all passed** (after `sudo ufw allow in on docker0`):
  goose dev + reviewer ACP handshakes with `X-Secret-Key`, 401 negative test,
  clean teardown via launcher endpoints.

### ADR-08 addendum — Multi-machine state sync (2026-11-08, as-built record: [`docs/phases/07-state-sync-adr08.md`](docs/phases/07-state-sync-adr08.md))
- **`setup-sync.sh`** — scaffolds/adopts the private repo (default
  `~/sisyphus-state/`; this deployment: `~/Projects/sisyphus-state/` via
  `SISYPHUS_STATE_DIR`), seeds the strict `.gitignore` (SQLite, `*.sql.gz`,
  `backups/`, pgdata, secrets), migrates text state, creates the
  `storage/ → <state-repo>/` symlinks (memories, MEMORY.md, goose
  configs). Idempotent; safe to re-run on every machine.
- **`sync-export.sh`** — sanitized `pg_dump` (keeps hashed `account`,
  excludes the five plaintext-secret tables) → **FK-repair in the export
  pipeline** via `repair-dump.py` → checksum → blocked-file verification →
  commit (+ push if a remote exists). The committed dump is **import-ready by
  construction**.
- **`repair-dump.py`** — parses the dump's own FK graph and emulates the FK
  actions on rows referencing excluded secret tables (`CASCADE` → drop row;
  `SET NULL`/`RESTRICT`/`NO ACTION` → null the column).
- **`sync-import.sh`** — gated restore: refuses dirty state / running
  Paperclip / failed checksum / leaked secret-table rows; drops **both**
  `public` and `drizzle` schemas before restoring; post-restore row counts.
- **Clean-slate E2E validation (2026-11-08)** — full purge-and-rebirth:
  `stop.sh` → wipe `storage/` + `workspace/` → `setup-sync.sh` → `start.sh`
  (fresh pgdata) → `sync-import.sh --yes` (**users=3, companies=2** restored)
  → `test_container_connectivity.sh` **all green**. Three defects found &
  fixed during the cycle: FK-dangling dump rows (→ export-side repair), the
  `drizzle` schema surviving the import wipe, and a `grep` option-parsing
  bug. Private repo commit `0af12f1`; re-export `e855563`.
- **State-repo relocation (2026-11-08)** — the private repo was moved from
  the default `~/sisyphus-state/` to **`~/Projects/sisyphus-state/`**
  (non-default). All `storage/` symlinks (absolute paths) were rebuilt via
  `SISYPHUS_STATE_DIR=~/Projects/sisyphus-state ./execution-plane/scripts/setup-sync.sh`;
  script auto-discovery verified against the new location. Operators should
  `export SISYPHUS_STATE_DIR="$HOME/Projects/sisyphus-state"` in the shell
  profile so discovery survives a future `storage/` purge.

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
  are the intended ADR-07 path. Re-verified in the 2026-11-08 clean-slate
  cycle.
- **ADR-08 sync tooling**: private-repo adoption is non-destructive
  (`setup-sync.sh` refuses to clobber a non-git directory); export-side FK
  repair makes sanitized dumps importable; `drizzle` schema must be dropped
  alongside `public` on import.

## Pending / open items

- **Phase 4**: `permission.yaml` is tracked and enforced at the
  tool-name level; pattern rules still require the wrapper enforcement
  layer. The env-scrub is present in the installed Hermes build.
  **None of the acceptance criteria are verified yet**: the
  `/proc/<pid>/environ` smart_approve check, the negative permission tests,
  and the `execute_code` PYTHONPATH test must be executed and evidenced per
  `docs/phases/04-security-mitigations.md`.
- **Phase 5**: `watchdog-locks.sh` is implemented (hooked into the launcher
  every 600 s); its acceptance criteria are unverified. The #6596 backoff
  deliverable is to be implemented per
  `docs/phases/05-reliability-watchdog.md`.
- **Phase 6**: not started.
- **Human step**: Paperclip one-time onboarding at <http://localhost:3000>
  (company + owner account), after which the smoke-ticket test can run.
- **Secret re-entry after any ADR-08 import** (by design, R8): provider/agent
  keys must be re-entered in the Paperclip UI — the dump excludes the
  plaintext-secret tables.
