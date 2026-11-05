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
| 4 | Security mitigations | ⬜ **Next** |
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

1. **Human step (pending):** Paperclip first-run onboarding at
   <http://localhost:3000> (`bootstrap_pending`). Unblocks the smoke-ticket
   test (Phase 6) and the full pipeline approval test (Phase 4).
2. **`run.ps1` unverified** — no `pwsh` on the reference host; mirrors tested
   `run.sh` logic.
3. **LLM keys** — `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` needed in `.env`
   before agent turns can run (Phase 6 E2E).
4. **`tool_permissions.json`** is a placeholder `{}` — Phase 4 fills it
   (schema validated against the installed goose build first).

## Next up — Phase 4 (security baseline)

PYTHONPATH env allowlist patch for Hermes `execute_code` (CVE-2026-9368),
verify `smart_approve` reaches every daemon runtime, write the tool
permission policy, enforce SQLite `journal_mode: delete`, run the negative
permission tests. See `docs/phases/04-security-mitigations.md`.
