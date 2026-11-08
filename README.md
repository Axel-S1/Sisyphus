# Sisyphus

**Local-First Multi-Agent System** — Paperclip · Hermes · Goose

A monorepo implementing a resilient, local-first multi-agent architecture where a **Control Plane** (Paperclip + PostgreSQL in Docker) orchestrates an **Execution Plane** (Hermes "thinkers" + Goose "executors" running natively on the host) through a network-based IPC gateway.

> **Status**: Phases 1–3 complete and verified. Phases 4–6 (security hardening, reliability watchdog, E2E validation) are pending. See [STATUS.md](STATUS.md) and [docs/phases/README.md](docs/phases/README.md).

---

## 🏗 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    CONTROL PLANE (Docker)                   │
│  ┌───────────────────┐        ┌──────────────────────────┐  │
│  │     Paperclip      │───────▶│  PostgreSQL (Drizzle ORM)│  │
│  │ (orchestrator,    │        └──────────────────────────┘  │
│  │  heartbeat,       │───────▶ storage/paperclip_data       │
│  │  adapters)        │        (bind mount)                  │
│  └─────────┬─────────┘                                      │
└────────────┼────────────────────────────────────────────────┘
             │  HTTP/REST + ACP (JSON-RPC 2.0) via host.docker.internal
             │  http://host.docker.internal:8642    (Hermes CEO)
             │  http://host.docker.internal:3284/acp (Goose Dev)
             │  http://host.docker.internal:3285/acp (Goose Reviewer)
             │  Auth: Hermes auth provider · X-Secret-Key (Goose)
┌────────────▼────────────────────────────────────────────────┐
│                  EXECUTION PLANE (Native host)              │
│  ┌──────────────────────┐      ┌──────────────────────────┐ │
│  │ Host Launcher (ADR-07)│ spawns on demand:                  │
│  │ launcher.py :9000     │  Hermes (Thinkers) │ Goose (Executors) │
│  │ idle watchdog 10 min  │  hermes serve :8642│ goose serve      │
│  │ run.sh / run.ps1      │  HERMES_HOME=...   │ GOOSE_PATH_ROOT= │
│  └──────────────────────┘      └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Decisions (ADRs)

| ADR | Decision |
|-----|----------|
| **ADR-01** | Control Plane ↔ Execution Plane via **HTTP/ACP network gateway** (`hermes serve`, `goose serve`); container→host via `host.docker.internal` |
| **ADR-02** | Security: `PYTHONPATH` scrub (CVE-2026-9368) + `GOOSE_MODE=smart_approve` (MVP) → ephemeral sandbox (post-MVP) |
| **ADR-03** | **Symmetric isolation**: every agent gets `HERMES_HOME` **and** `GOOSE_PATH_ROOT` injected |
| **ADR-04** | **Withdrawn** (v2.3): Execution Plane runs natively — WAL is correct |
| **ADR-05** | Paperclip mitigations: `sessionKeyStrategy: 'run'` + orphaned-lock watchdog + backoff |
| **ADR-06** | **Per-profile port registry** (`ports.env`) — one port per profile |
| **ADR-07** | **Host Launcher Micro-API** (`launcher.py` :9000) — on-demand spawn, 10-min idle teardown |
| **ADR-08** | **State Synchronization** — private Git repo (default `~/sisyphus-state/`; deployed: `~/Projects/sisyphus-state/` via `SISYPHUS_STATE_DIR`) holding text configs + sanitized SQL dumps; ephemeral SQLite and secrets never sync |

---

## 📁 Repository Structure

```
Sisyphus/
├── .env.example                      # Secrets template (copy to .env — git-ignored)
├── .gitignore                        # R8 mandatory lines + hygiene
├── docker-compose.yml                # Paperclip + PostgreSQL 16
├── STATUS.md                         # Progress tracker
├── start.sh / stop.sh                # One-button stack lifecycle
├── docs/
│   ├── spec/architecture-spec.md     # Authoritative architecture spec (v2.4)
│   └── phases/                       # 6-phase execution plan (1–3 done)
├── control-plane/paperclip/config/
│   ├── adapters.json                 # Network-only adapter contract
│   └── tool_permissions.json         # Tool permission policy (Phase 4)
├── execution-plane/
│   ├── scripts/
│   │   ├── run.sh / run.ps1          # Bootstrap wrappers (symmetric env injection)
│   │   ├── launcher.py               # Host Launcher Micro-API (ADR-07)
│   │   ├── ports.env.example         # Port registry template (ADR-06)
│   │   ├── setup-sync.sh             # ADR-08: private-repo scaffold + symlinks
│   │   ├── sync-export.sh            # ADR-08: sanitized + FK-repaired dump
│   │   ├── sync-import.sh            # ADR-08: gated, checksummed restore
│   │   ├── repair-dump.py            # ADR-08: FK-action repair of sanitized dumps
│   │   ├── watchdog-locks.sh         # Orphaned-lock purge (Phase 5, #3819)
│   │   ├── test_container_connectivity.sh  # Atomic Phase 3 test suite
│   │   ├── test_watchdog_locks.sh    # Watchdog acceptance harness (Phase 5)
│   │   └── test_security_baseline.sh # Security acceptance harness (Phase 4)
│   ├── profiles/
│   │   ├── ceo/hermes_config/        # SOUL.md, AGENTS.md
│   │   ├── dev/goose_config/         # config.yaml (smart_approve)
│   │   └── reviewer/goose_config/    # config.yaml (smart_approve)
│   └── workspace/                    # Agent deliverables
└── storage/                          # Persistence (git-ignored except .gitkeep)
    ├── paperclip_data/               # Paperclip state (bind mount)
    ├── paperclip_pgdata/             # PostgreSQL data
    ├── hermes_data/agent_*/          # HERMES_HOME per profile
    └── goose_data/agent_*/           # GOOSE_PATH_ROOT per profile
```

---

## 🚀 Quick Start

### Prerequisites

- **Docker** + Docker Compose plugin (or standalone `docker-compose`)
- **Python 3.10+** (for `launcher.py` and `repair-dump.py`)
- **Goose 1.56.0+** installed and on `PATH` (`goose serve` command)
- **Hermes v0.22.7+** installed and on `PATH` (`hermes serve` command)
- **Linux** (reference host; macOS/WSL2 supported with firewall adjustments)

### 0. Migrating an existing machine's state (ADR-08)

If you already have a private state repo, restore your identity before first
boot. Clone it wherever you like — the scripts auto-discover it via the
`storage/` symlinks — but **keep the location stable** and export
`SISYPHUS_STATE_DIR` if it is not the default `~/sisyphus-state/` (this
deployment uses `~/Projects/sisyphus-state/`):

```bash
git clone git@github.com:YOU/sisyphus-state.git ~/Projects/sisyphus-state
export SISYPHUS_STATE_DIR="$HOME/Projects/sisyphus-state"   # in ~/.bashrc, if non-default
./execution-plane/scripts/setup-sync.sh        # adopts it, rebuilds symlinks
./start.sh                                     # launcher + Paperclip + fresh PostgreSQL
docker compose stop paperclip                  # import gate: Paperclip must be DOWN
./execution-plane/scripts/sync-import.sh       # restores the DB (checksummed, gated)
docker compose up -d paperclip                 # control plane back up
```

Re-enter provider/agent API keys in the Paperclip UI afterwards — plaintext
secret tables are excluded from dumps by design (R8). Logins survive.

For a brand-new installation (no prior state), skip this section and follow
steps 1–6 below.

### 1. Clone & Configure

```bash
git clone <this-repo> Sisyphus
cd Sisyphus

# Copy environment templates
cp .env.example .env
cp execution-plane/scripts/ports.env.example execution-plane/scripts/ports.env

# Edit .env with your secrets (required):
#   POSTGRES_PASSWORD=...
#   BETTER_AUTH_SECRET=...          # 32+ char random string
#   GOOSE_SERVER__SECRET_KEY=...    # Goose ACP auth
#   LAUNCHER_SECRET=...             # Launcher API auth (for non-loopback bind)
#   PAPERCLIP_PUBLIC_URL=http://localhost:3000
#   ANTHROPIC_API_KEY=...           # or OPENAI_API_KEY (for agent runs)
#   API_SERVER_KEY=...              # Hermes auth provider secret (future)
```

### 2. Start the Stack

```bash
./start.sh
```

This will:
1. Start the **Host Launcher** on `http://127.0.0.1:9000` (with `X-Launcher-Secret` auth)
2. Bring up **Paperclip + PostgreSQL** via Docker Compose
3. Print a readiness banner with all endpoints

### 3. Paperclip First-Time Onboarding (Human Step)

Open **http://localhost:3000** in your browser:
- Create the first **Company**
- Create the **Owner** account
- This is required before the Control Plane can schedule work (authenticated mode)

### 4. Launch Agents On Demand

The Host Launcher spawns Execution Plane daemons only when needed:

```bash
# Launch Hermes CEO (thinker)
curl -X POST "http://127.0.0.1:9000/launch?profile=ceo&engine=hermes" \
  -H "X-Launcher-Secret: $LAUNCHER_SECRET"

# Launch Goose Dev (executor)
curl -X POST "http://127.0.0.1:9000/launch?profile=dev&engine=goose" \
  -H "X-Launcher-Secret: $LAUNCHER_SECRET"

# Launch Goose Reviewer (executor)
curl -X POST "http://127.0.0.1:9000/launch?profile=reviewer&engine=goose" \
  -H "X-Launcher-Secret: $LAUNCHER_SECRET"
```

Daemons are torn down automatically after **10 minutes of no traffic** (liveness-probed).

### 5. Check Status

```bash
# Launcher status (all managed daemons)
curl "http://127.0.0.1:9000/status" -H "X-Launcher-Secret: $LAUNCHER_SECRET"

# Paperclip UI
open http://localhost:3000
```

### 6. Stop the Stack

```bash
./stop.sh
```

This gracefully shuts down Docker Compose, the Host Launcher, and any repo-managed daemons (preserving your own desktop Goose/Hermes sessions).

---

## 🔧 Configuration Details

### Environment Files

| File | Purpose | Git Status |
|------|---------|------------|
| `.env` | All secrets (DB, API keys, auth) | **Ignored** (R8) |
| `execution-plane/scripts/ports.env` | Profile → port registry (ADR-06) | **Ignored** |
| `.env.example` / `ports.env.example` | Templates | Tracked |

**Required `.env` keys:**
```bash
POSTGRES_PASSWORD=              # PostgreSQL password
BETTER_AUTH_SECRET=             # Paperclip session signing (32+ chars)
GOOSE_SERVER__SECRET_KEY=       # Goose ACP auth header (X-Secret-Key)
LAUNCHER_SECRET=                # Host Launcher API auth (X-Launcher-Secret)
PAPERCLIP_PUBLIC_URL=           # e.g. http://localhost:3000
ANTHROPIC_API_KEY=              # or OPENAI_API_KEY (for LLM calls)
# API_SERVER_KEY=               # Hermes auth provider (when configured)
```

### Port Registry (`ports.env`)

```bash
HERMES_PORT_CEO=8642
GOOSE_PORT_DEV=3284
GOOSE_PORT_REVIEWER=3285
```

One port per profile — **two profiles on one port = guaranteed crash-loop** (ADR-06).

### Multi-Machine State Sync (private `sisyphus-state` repo, ADR-08)

The public repo is state-neutral. Your *portable* state — agent personas,
engine configs, Hermes memories, and a **sanitized** Paperclip SQL dump —
lives in a **private** Git repo, entirely separate from the public repo.
Ephemeral SQLite DBs and secrets never sync (see ADR-08 in the spec).

**Where the repo lives — resolution order:**

1. `argv[1]`: `./execution-plane/scripts/setup-sync.sh /any/path`
2. `SISYPHUS_STATE_DIR` environment variable
3. Default: `~/sisyphus-state/`
4. Runtime fallback: `sync-export.sh`/`sync-import.sh` also discover the repo
   by walking up from the `storage/` symlinks — so a non-default location
   works without env vars once the links exist.

> **This deployment uses `~/Projects/sisyphus-state/`.** Set it once in your
> shell profile so discovery survives even a purged workspace:
>
> ```bash
> export SISYPHUS_STATE_DIR="$HOME/Projects/sisyphus-state"
> ```

**Moving or relocating the repo**: the `storage/` symlinks are absolute, so
after any move re-run
`SISYPHUS_STATE_DIR=<new-path> ./execution-plane/scripts/setup-sync.sh` — it
detects stale links and rebuilds them (never edit them by hand).

```bash
# One-time, per machine (idempotent; adopts an existing repo, never clobbers):
./execution-plane/scripts/setup-sync.sh        # or: setup-sync.sh ~/Projects/sisyphus-state

# Leaving machine A:
./execution-plane/scripts/sync-export.sh       # sanitized + FK-repaired dump, commit/push

# Arriving on machine B:
git -C "$SISYPHUS_STATE_DIR" pull
./execution-plane/scripts/sync-import.sh       # restore dump (Paperclip must be DOWN; postgres UP)
```

> **Import ordering tip**: `./start.sh` brings up Paperclip **and** Postgres,
> but `sync-import.sh` requires Paperclip to be **down** (it drops and
> recreates the schema). On machine B after `start.sh`, run
> `docker compose stop paperclip` before `sync-import.sh`, then
> `docker compose up -d paperclip` afterwards — `sync-import.sh` enforces
> these gates and will refuse an unsafe restore.

The export pipeline **guarantees an import-ready dump**: after the sanitized
`pg_dump`, `repair-dump.py` emulates the schema's own FK actions on rows that
reference the excluded secret tables (CASCADE → drop, SET NULL/RESTRICT →
nullify), so the committed `.sql` never contains FK-dangling rows
(verified by the 2026-11-08 clean-slate E2E — see
[docs/phases/07-state-sync-adr08.md](docs/phases/07-state-sync-adr08.md)).

Rules of thumb: export before you switch machines, import after you arrive,
and never run agents on two machines against the same identity at once
(async, last-writer-wins). Plaintext secret tables (`company_secrets`,
`agent_api_keys`, …) are excluded from dumps — after an import, re-enter
provider/agent API keys in the Paperclip UI. Logins survive the round-trip
(the hashed `account` table is kept). Full-fidelity `.sql.gz` auto-backups
are hard-blocked from the private repo.

### Firewall (Linux)

Container→host traffic requires docker0 ingress:

```bash
sudo ufw allow in on docker0
```

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [STATUS.md](STATUS.md) | Current progress tracker |
| [docs/spec/architecture-spec.md](docs/spec/architecture-spec.md) | Authoritative architecture specification (v2.4) |
| [docs/phases/README.md](docs/phases/README.md) | 6-phase execution plan index |
| [docs/phases/01-monorepo-scaffolding.md](docs/phases/01-monorepo-scaffolding.md) | Phase 1: Repo structure, gitignore, env templates |
| [docs/phases/02-execution-plane-daemons.md](docs/phases/02-execution-plane-daemons.md) | Phase 2: run.sh, profiles, collision test |
| [docs/phases/03-control-plane-paperclip.md](docs/phases/03-control-plane-paperclip.md) | Phase 3: Paperclip, launcher, connectivity tests |
| [docs/phases/04-security-mitigations.md](docs/phases/04-security-mitigations.md) | Phase 4: CVE patch, smart_approve, permission rules |
| [docs/phases/05-reliability-watchdog.md](docs/phases/05-reliability-watchdog.md) | Phase 5: Orphaned-lock watchdog, exponential backoff |
| [docs/phases/06-e2e-validation.md](docs/phases/06-e2e-validation.md) | Phase 6: Go/No-Go checklist |
| [docs/phases/07-state-sync-adr08.md](docs/phases/07-state-sync-adr08.md) | **ADR-08 addendum**: multi-machine state sync + clean-slate E2E validation (as-built) |

---

## 🧪 Testing

### Container Connectivity Suite (Phase 3)

```bash
./execution-plane/scripts/test_container_connectivity.sh
cat /tmp/phase3_conn_test.log    # the script is self-quieting — results land here
```

> **Note (DX)**: the script redirects all of its output to
> `/tmp/phase3_conn_test.log`. An empty terminal after the run does **not**
> mean it failed — read the log, or check for the final
> `=== TEST BLOCK COMPLETE ===` marker.

Validates:
- Goose Dev ACP handshake (`initialize` + `X-Secret-Key`) from inside container ✅
- Goose Reviewer ACP handshake ✅
- Negative test: 401 without auth header ✅
- Clean teardown via launcher endpoints ✅

### Launcher API

```bash
# Status
curl -H "X-Launcher-Secret: $LAUNCHER_SECRET" http://127.0.0.1:9000/status

# Launch
curl -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" \
  "http://127.0.0.1:9000/launch?profile=dev&engine=goose"

# Touch (reset idle timer)
curl -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" \
  "http://127.0.0.1:9000/touch?profile=dev"

# Shutdown
curl -X POST -H "X-Launcher-Secret: $LAUNCHER_SECRET" \
  "http://127.0.0.1:9000/shutdown?profile=dev"
```

---

## ⚠️ Known Constraints & Gotchas

| Area | Constraint |
|------|------------|
| **Goose server** | Use `goose serve --host 0.0.0.0 --port <p>` (flags mandatory; env vars ignored in 1.56.0) |
| **Goose auth** | Header **`X-Secret-Key`** (not `Authorization: Bearer`) |
| **Hermes server** | Use `hermes serve --port <p> --host 0.0.0.0` (NOT `hermes gateway` or `hermes acp`) |
| **Hermes auth** | Non-loopback bind requires Hermes's **own auth provider** (password/OAuth) — `--insecure` is a no-op |
| **Paperclip adapter secrets** | Stored as **Paperclip secret references** (UI/API), NOT container env vars |
| **Session strategy** | `sessionKeyStrategy: 'run'` (fresh session per run); `persistSession` field does not exist |
| **SQLite WAL** | Native host filesystem → WAL is correct (ADR-04 withdrawn) |
| **Secrets hygiene** | Never commit `.env`, `ports.env`, `storage/**/agent_*/**` (all in `.gitignore`) |

---

## 🔐 Security Model (MVP)

1. **CVE-2026-9368 patch**: `PYTHONPATH` stripped from all `execute_code` subprocesses (env allowlist)
2. **`GOOSE_MODE=smart_approve`**: Human approval required for destructive tool calls
3. **Tool permission policy**: `permission.yaml` (tracked) + `tool_permissions.json` (durable intent)
   - Blocks: `.env`, `secrets/`, `id_rsa`, `.ssh/`, `rm -rf /`
   - Requires approval: force-push to `main`
   - Allows: `pytest`, `npm test`, `cargo test`
4. **Post-MVP**: Ephemeral container sandboxing → controlled return to `auto` mode

---

## 🛠 Development

### Adding a New Profile

1. Create `execution-plane/profiles/<name>/<engine>_config/`
2. Add port to `ports.env.example` (e.g., `GOOSE_PORT_<NAME>=xxxx`)
3. Add adapter entry to `control-plane/paperclip/config/adapters.json`
4. Update `run.sh`/`run.ps1` profile detection if needed

### Modifying the Launcher

```bash
# Run directly (for dev)
python3 execution-plane/scripts/launcher.py --host 127.0.0.1 --port 9000
```

### Running Paperclip Locally (Outside Docker)

Not recommended for MVP — the architecture assumes containerized Control Plane with `host.docker.internal` networking.

---

## 📄 License

Proprietary / Internal — see [architecture-spec.md](docs/spec/architecture-spec.md) for IP context.

---

## 🤝 Contributing

This is a phased, specification-driven project. See [docs/phases/README.md](docs/phases/README.md) for the execution protocol:

1. Read the phase doc end-to-end before writing code
2. Do exactly one phase per run
3. Verify every acceptance criterion yourself
4. Never modify settled ADRs (spec §3 wins)
5. Secrets hygiene (R8) is non-negotiable

---

*Generated from architecture-spec.md v2.4 — see [STATUS.md](STATUS.md) for current phase status.*