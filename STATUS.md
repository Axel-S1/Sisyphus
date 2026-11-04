# Project Status — Sisyphus (updated 2026-11-04)

Progress tracker for the 6-phase MVP plan ([`phases/README.md`](phases/README.md)).

| # | Phase | Status |
|---|-------|--------|
| 1 | Monorepo scaffolding | ✅ Done (`7fa1fda`, `52f138e`) |
| 2 | Execution plane daemons | ✅ Done (`d3c0c0a`) |
| 3 | Control plane (Paperclip) | ⬜ Next |
| 4 | Security mitigations | ⬜ Pending |
| 5 | Reliability watchdog | ⬜ Pending |
| 6 | E2E validation | ⬜ Pending |

## What is done

### Phase 1 — Monorepo scaffolding
- Full directory tree (control-plane, execution-plane, storage, phases).
- `.gitignore` with the six spec-mandated lines (R8: `.env`, `ports.env`,
  `storage/goose_data/**`, Hermes sessions/logs, workspace) + hygiene rules
  and `.gitkeep` negations so placeholder dirs stay tracked.
- `.env.example` (distinct `API_SERVER_KEY` / `GOOSE_SERVER__SECRET_KEY`) and
  `execution-plane/scripts/ports.env.example` (ADR-06 port registry).
- Placeholders: `docker-compose.yml`, `adapters.json`, `tool_permissions.json`.

### Phase 2 — Execution plane daemons
- `execution-plane/scripts/run.sh` (POSIX bootstrap): loads `.env` +
  `ports.env`, injects `HERMES_HOME` + `GOOSE_PATH_ROOT` per profile (ADR-03,
  hard-fail if missing), resolves the profile port from the ADR-06 registry,
  then execs `goose serve` (never `goose acp` — Risk R9) or `hermes gateway run`.
- `run.ps1` — PowerShell equivalent (syntax check pending, no pwsh installed).
- systemd template units (`goose-serve@.service`, `hermes-gateway@.service`,
  `Restart=on-failure`, secrets from `.env`, never inlined) plus
  `install-systemd.sh` installer.
- Profile configs: `dev`/`reviewer` Goose (`GOOSE_MODE: smart_approve`), `ceo`
  Hermes (`SOUL.md`, `AGENTS.md` placeholders).

### Verified against the installed build (goose 1.56.0)
- `goose serve` serves HTTP/WS ACP on `/acp`; **auth header is
  `X-Secret-Key`** (not `Authorization: Bearer` as the spec sketch suggested).
- goose **ignores** `GOOSE_SERVER__HOST`/`GOOSE_SERVER__PORT` env vars — ports
  are passed as CLI flags (`--host 0.0.0.0 --port <port>`).
- `GOOSE_PATH_ROOT` fully redirects config/data/state (incl. `sessions.db`),
  `GOOSE_MODE=smart_approve` is a valid mode.
- Concurrency collision test passed: `dev` (:3284) and `reviewer` (:3285) ran
  simultaneously with zero cross-writes; `~/.config/goose/` and
  `~/.local/share/goose/` stayed untouched.
- Handshake: HTTP 200 JSON-RPC 2.0 `initialize` with secret; **401** without.

## What is next

**Phase 3 — Control Plane (Paperclip)** — in progress:
- ✅ **Task 0 (ADR-07): Host Launcher + one-button scripts** — `launcher.py`
  (stdlib HTTP on :9000, `/launch`, `/shutdown`, `/touch`, `/status`,
  10-min idle watchdog), `start.sh`/`stop.sh`. End-to-end test passed:
  `/launch?profile=dev&engine=goose` spawned the daemon via `run.sh`, a
  live JSON-RPC handshake succeeded on :3284, `/shutdown` closed the port.
- ⬜ `adapters.json` (hermes_gateway :8642, goose ACP :3284/acp,
  `persistSession: false`)
- ⬜ Connectivity tests from inside the Paperclip container
- ⬜ Drizzle/PostgreSQL persistence check

**Phase 3 endpoints recorded for `adapters.json`:**

| Adapter target | URL | Auth header |
|---|---|---|
| Goose dev | `http://host.docker.internal:3284/acp` | `X-Secret-Key` |
| Goose reviewer | `http://host.docker.internal:3285/acp` | `X-Secret-Key` |
| Hermes ceo | `http://host.docker.internal:8642` | verify against installed build |
| Host Launcher | `http://host.docker.internal:9000` (if container-triggered) | `X-Launcher-Secret` |

## Current problems / blockers

1. **Hermes spec adaptation (RESOLVED 2026-11-04, needs spec text update)** —
   Hermes v0.22.7 is now installed. The spec's assumed command
   `hermes gateway run --port 8642` is wrong for this build: `hermes
   gateway` is a *messaging* gateway (Telegram/Discord) with no `--port`.
   The actual HTTP daemon is **`hermes serve --port 8642 --host <bind>`**
   (JSON-RPC/WebSocket, smoke-tested: binds and reports
   `HERMES_BACKEND_READY port=8642`). Auth differs from the spec too: a
   non-loopback bind requires Hermes's own auth provider (password/OAuth),
   not a plain `API_SERVER_KEY` env var — `--insecure` is a no-op as of
   June 2026 hardening. `run.sh` must be updated to exec `hermes serve` and
   the durable contract (HTTP endpoint, one port per profile) stays intact.
   `hermes acp` exists but is stdio-only (same Risk R9 class as `goose acp`)
   — never use it for the network daemon.
2. ~~**systemd units not installed** — installer needs sudo (no passwordless
   sudo available to the agent)~~ — **RESOLVED / OBSOLETE (2026-11-04)**:
   systemd daemons are officially deprecated by ADR-07 (Host Launcher
   Micro-API). The unit templates and `install-systemd.sh` have been removed
   from the repo; daemons are spawned on demand by the launcher via
   `run.sh`/`run.ps1` and torn down after a 10-minute idle timeout.
3. **`run.ps1` unverified** — no `pwsh` on this host; logic mirrors the tested
   `run.sh` but has never executed.
4. **Paperclip not yet built/obtained** — nothing exists in
   `control-plane/paperclip/` besides config placeholders; Phase 3 needs the
   actual Paperclip codebase and its `adapters.json` schema to validate the
   adapter URL variable names (spec flags them as illustrative).
5. **LLM keys not set** — `.env` has empty `ANTHROPIC_API_KEY` /
   `OPENAI_API_KEY`; agent turns requiring a provider will fail until set.
