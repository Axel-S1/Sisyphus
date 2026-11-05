# Phase 2/6 — Execution Plane Daemons — **AS-BUILT RECORD** ✅

> Status: **Complete** (commit `d3c0c0a` + `1cc513a` fix + `6ac76fb` systemd
> deprecation). Executed 2026-11-03/04 against **Hermes v0.22.7** and
> **goose 1.56.0**. Spec reference: §2.3, §2.4, ADR-01, ADR-03, ADR-06.

## What was built

### `execution-plane/scripts/run.sh` (bootstrap wrapper — the core artifact)

Behaviour (full source in the script):

1. Tolerates offline host: `git pull --rebase || true`.
2. Loads `.env` and `ports.env`; **hard-fails** if either is missing.
3. **ADR-03 symmetric injection**: exports `HERMES_HOME` and `GOOSE_PATH_ROOT`
   per profile (`storage/hermes_data/agent_<p>`, `storage/goose_data/agent_<p>`),
   creates both dirs, hard-fails if either variable ends up empty.
4. Seeds the profile config into the engine's isolated root **without
   overwriting** existing files (never clobbers live state).
5. **ADR-06 port registry** lookup: `HERMES_PORT_CEo`, `GOOSE_PORT_DEV`,
   `GOOSE_PORT_REVIEWER` … (exact registry names; `CEo` is the registry's
   casing), hard-fails on a missing port entry.
6. Engine selection (v2.2 verified commands):
   - **Goose**: `GOOSE_MODE=smart_approve`, then
     `goose serve --host 0.0.0.0 --port <GOOSE_PORT_*>`.
     ⚠️ Flags, not env vars — goose 1.56.0 **ignores**
     `GOOSE_SERVER__HOST`/`GOOSE_SERVER__PORT`. Never `goose acp` (stdio-only).
   - **Hermes**: `hermes serve --port <HERMES_PORT_*> --host 0.0.0.0`.
     ⚠️ Adapted from the spec's historical `hermes gateway run`, which does
     **not exist** in Hermes v0.22.7 (`hermes gateway` is a messaging gateway
     for Telegram/Discord). `hermes acp` is stdio-only — same R9 class.
     A non-loopback bind requires Hermes's own auth provider (the June 2026
     hardening; `--insecure` is a no-op).
   - `auto`: picks goose if the profile has `goose_config/`, else hermes.

`run.ps1` mirrors this logic in PowerShell (mirror of the tested `run.sh`;
flagged **untested** — no pwsh on the reference host).

### Profile configs

- `execution-plane/profiles/dev/goose_config/config.yaml` and
  `reviewer/...`: seed `GOOSE_MODE: smart_approve` (MVP mode, R7).
- `execution-plane/profiles/ceo/hermes_config/`: `SOUL.md`, `AGENTS.md`
  placeholders (frozen document-injection model).

### systemd units — REMOVED (ADR-07)

Persistent systemd daemons were **superseded by the Host Launcher Micro-API**
(`launcher.py`, port 9000 — Phase 3): daemons spawn on demand via `run.sh` and
tear down after a 10-minute idle timeout. The unit templates and their
installer were removed from the repo (`6ac76fb`).

## Critical facts (memorize — Risk R9)

- Network daemons: **`goose serve`** (HTTP/WS ACP, `/acp`, JSON-RPC 2.0) and
  **`hermes serve`** (HTTP). Nothing else.
- `goose acp` / `hermes acp` are **stdio-only** (editor clients); `hermes
  gateway` is a **messaging** gateway. Any of them run as a "daemon" listens
  on nothing — silently.
- goose 1.56.0 ignores `GOOSE_SERVER__HOST`/`GOOSE_SERVER__PORT` env vars;
  pass `--host 0.0.0.0 --port <port>` as **CLI flags**.
- Goose auth header is **`X-Secret-Key: <GOOSE_SERVER__SECRET_KEY>`**
  (verified: `Authorization: Bearer` is rejected with 401).
- Goose ignores `HERMES_HOME` — per-profile isolation strictly requires
  `GOOSE_PATH_ROOT` (ADR-03).

## Verification evidence

- [x] `run.sh dev goose` starts `goose serve` bound to `0.0.0.0:<port>`
      (verified with `ss -ltnp`, not 127.0.0.1).
- [x] `/acp` answers a JSON-RPC 2.0 `initialize` handshake **with** the
      secret (HTTP 200); **refuses without** it (401).
- [x] **Collision test passed (concurrent)**: `dev` (:3284) and `reviewer`
      (:3285) ran simultaneously with distinct `GOOSE_PATH_ROOT`s; zero
      cross-writes to `~/.config/goose/` / `~/.local/share/goose/` — each
      instance wrote only inside its own `storage/goose_data/agent_<profile>/`.
- [x] `run.sh` hard-fails when `HERMES_HOME`/`GOOSE_PATH_ROOT` cannot be set
      (simulated unset-variable run).
- [x] No daemon was ever started with `goose acp` (searched command history /
      logs during the run).
- [x] Hermes: `hermes serve --port 8642 --host 0.0.0.0` binds and reports
      `HERMES_BACKEND_READY port=8642`.

## Deviations from the original sketch

| Sketch | As-built | Reason |
|---|---|---|
| `hermes gateway run --port 8642` | `hermes serve --port … --host …` | Command does not exist in v0.22.7; gateway is messaging-only |
| `GOOSE_SERVER__HOST/PORT` env vars | CLI flags `--host/--port` | goose 1.56.0 ignores those env vars |
| `Authorization: Bearer` header | `X-Secret-Key` header | Bearer rejected with 401 (verified) |
| systemd units `Restart=on-failure` | Removed; ADR-07 launcher | Resource hogging of permanent daemons; one-button control |
| Hermes auth = plain `API_SERVER_KEY` header | Non-loopback bind requires Hermes auth provider | June 2026 hardening; `--insecure` is a no-op |

## Outputs consumed by later phases

Phase 3 points Paperclip's adapters at `http://host.docker.internal:<ports>`
(:8642 Hermes, :3284 dev, :3285 reviewer) using these exact commands and auth
headers; Phase 4 hardens the running daemons (CVE patch, permission policy,
SQLite journal modes).
