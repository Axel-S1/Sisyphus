# Project Status — Sisyphus (updated 2026-11-05)

Progress tracker for the 6-phase MVP plan — see
[`docs/phases/README.md`](docs/phases/README.md) and the architecture spec
[`docs/spec/architecture-spec.md`](docs/spec/architecture-spec.md) (v2.2,
implementation-verified).

| # | Phase | Status |
|---|-------|--------|
| 1 | Monorepo scaffolding | ✅ Done (`7fa1fda`, `52f138e`) |
| 2 | Execution plane daemons | ✅ Done (`d3c0c0a`, `1cc513a`) |
| 3 | Control plane (Paperclip) | ✅ Done (`c3224d2`, `67aba3f`, `de6a38a`) |
| 4 | Security mitigations | ✅ Done (env scrub verified, smart_approve confirmed, SQLite journal-mode enforced) |
| 5 | Reliability watchdog | ⬜ Pending |
| 6 | E2E validation & Go/No-Go | ⬜ Pending |

> **Documentation set (2026-11-05):** the whole doc tree was restructured —
> the spec is now `docs/spec/architecture-spec.md` (v2.2 with every
> implementation-verified correction), phase docs live in `docs/phases/`
> (phases 1–3 as as-built records with verification evidence; 4–6 as plans),
> and this tracker replaced the stale narrative.

## What is done

### Phase 1 — Monorepo scaffolding
- Full directory tree (control-plane, execution-plane, storage, docs).
- `.gitignore` with the six spec-mandated lines (R8) + hygiene rules +
  `.gitkeep` negations + `storage/paperclip_pgdata/` + launcher logs.
- `.env.example` (distinct `API_SERVER_KEY` / `GOOSE_SERVER__SECRET_KEY` +
  Paperclip bootstrap secrets) and `ports.env.example` (ADR-06 registry).

### Phase 2 — Execution plane daemons
- `run.sh` / `run.ps1`: load `.env` + `ports.env`, inject `HERMES_HOME` +
  `GOOSE_PATH_ROOT` symmetrically (ADR-03, hard-fail), resolve profile port
  from the registry, exec the correct server command.
- Profile configs: `dev`/`reviewer` Goose (`GOOSE_MODE: smart_approve`),
  `ceo` Hermes (`SOUL.md`, `AGENTS.md`).
- systemd templates were **removed** — deprecated by ADR-07 (Host Launcher).

### Phase 3 — Control plane (Paperclip)
- **Host Launcher Micro-API (ADR-07)**: `launcher.py` (:9000, `/launch`,
  `/shutdown`, `/touch`, `/status`, 10-min idle watchdog) +
  `start.sh`/`stop.sh` one-button scripts.
- **Real Paperclip in Docker**: `ghcr.io/paperclipai/paperclip:latest`
  (UI/API host :3000 → container :3100) + external PostgreSQL 16 with
  `DATABASE_URL`; Drizzle migrations applied at boot; health checks green.
- **adapters.json**: network-only adapter contract with real-schema mapping
  (`sessionKeyStrategy: 'run'` as the durable equivalent of the historical
  `persistSession:false`; hermes_local forbidden in-container per ADR-01).
- **Atomic connectivity suite**: `test_container_connectivity.sh`.
- In-container tests **all passed** (after `sudo ufw allow in on docker0`):
  goose dev + reviewer ACP handshakes with `X-Secret-Key`, 401 negative test,
  launcher loopback-by-design verification, clean teardown via launcher
  endpoints.

## Verified facts (validated against installed builds)

- **Goose 1.56.0**: `goose serve --host 0.0.0.0 --port <p>` (env vars for
  host/port are ignored — CLI flags required); auth header **`X-Secret-Key`**
  (`Authorization: Bearer` → 401); ACP `initialize` needs an integer
  `protocolVersion`; `GOOSE_PATH_ROOT` fully redirects config/data/state;
  `GOOSE_MODE=smart_approve` valid; concurrent profiles had **zero
  cross-writes**.
- **Hermes v0.22.7**: the HTTP daemon is **`hermes serve --port <p> --host
  0.0.0.0`** — `hermes gateway` is a messaging gateway (no `--port`), and
  `hermes acp` is stdio-only. Non-loopback binds require Hermes's own auth
  provider (not a plain env key; `--insecure` is a no-op).
- **Paperclip (ghcr.io/paperclipai/paperclip)**: serves :3100; external
  Postgres via `DATABASE_URL`; requires `BETTER_AUTH_SECRET`; migrations at
  boot; **no `persistSession` field** — the durable equivalent is
  `sessionKeyStrategy: 'run'`; no native Goose adapter (ACP route via goose
  serve is the contract); adapter secrets stored as Paperclip secret refs,
  not container env.
- **Networking**: host firewall must `allow in on docker0` for container→host
  traffic; launcher stays loopback-only by design.

## Blockers / open items
### Phase 4 — Security mitigations (as-built, 2026-11-05)

- **T1 — CVE-2026-9368 (Hermes `execute_code` env scrub)**: the installed
  Hermes build (`/opt/hermes-agent`, `tools/code_execution_env.py`) already
  implements the ADR-02.1 mitigation: `_scrub_child_env` strips
  `PYTHONPATH`/`PYTHONHOME`, blocks secret-substring env names, and injects
  `PYTHONDONTWRITEBYTECODE=1`; `_build_child_env` re-injects only trusted
  entries (staging dir + Hermes root). Every spawn path routes through
  `_build_child_env` (per-call via `code_execution_tool`, session kernel via
  `code_kernel.py`, local env via `local.py`) — the "patch only one path"
  pitfall does not apply. Verified at function level with the real Hermes
  venv interpreter: poisoned `PYTHONPATH=/tmp/attacker_controlled` and
  `PYTHONHOME` are stripped, secret-named vars blocked, and the built child
  env PYTHONPATH is `/tmp/stage:/opt/hermes-agent` only.
- **T2 — `GOOSE_MODE=smart_approve` at runtime**: launched both profiles via
  the Host Launcher and inspected `/proc/<pid>/environ`: dev (pid 48481) and
  reviewer (pid 48516) both report `GOOSE_MODE=smart_approve` with correct
  per-profile `GOOSE_PATH_ROOT`. Config/env agree; teardown via launcher
  endpoints only (Goose Desktop pid 21836 untouched).
- **T3 — `tool_permissions.json` policy installed**:
  `control-plane/paperclip/config/tool_permissions.json` carries the four
  target rules (`.env`/secrets block, `rm -rf` block, push-to-main approval,
  pytest allow) plus an explicit enforcement note that goose 1.56.0 only
  supports tool-name-level permissions in `permission.yaml` — pattern rules
  require the Paperclip adapter layer or a wrapper.
- **T4 — SQLite `journal_mode=delete` (ADR-04)**:
  `execution-plane/scripts/ensure-sqlite-modes.sh` walks every SQLite DB
  under `storage/` (not just goose sessions), applies
  `PRAGMA journal_mode=delete`, and hard-fails if verification finds a
  non-delete mode; wired into `run.sh` before the engine case. Verified:
  both profile DBs converted wal -> delete. Observed that a running daemon
  had reverted its DB to wal, confirming the spec's "DBs change after the
  script runs" pitfall — the per-start hook is required, not optional.
- **T5 — `test_security_baseline.sh`**: idempotent verification suite
  covering all four acceptance checks (SQLite modes, CVE scrub negative
  test, smart_approve env/config agreement, policy JSON validity). All
  checks pass (exit 0).

## Next up — Phase 5 (reliability watchdog)

Watchdog heartbeat/detection (#3819) and exponential backoff (#6596) against
the live Paperclip schema (`issues`/`heartbeat_runs`/`routine_runs` tables
verified present in the paperclip_postgres instance).
