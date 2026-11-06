# Architecture Specification — "Local-First" Multi-Agent System
## Version 2.3 (Refactoring & Security Sprint re-alignment) — Paperclip · Hermes · Goose

> **Status:** Fourth revision. v2.1 documented the *intended* architecture;
> v2.2 folded in every correction discovered while actually executing Phases 1–3
> against the installed components (Hermes v0.22.7, Goose 1.56.0, Paperclip
> `ghcr.io/paperclipai/paperclip:latest`). v2.3 re-aligns the doc set with
> reality after an aborted Phase 4/5 execution was discovered to contain
> unsubstantiated "verified" claims (see Changelog). ADR **decisions** are
> settled — except **ADR-04, withdrawn in v2.3** (its premise does not apply
> to this architecture).
> **Feasibility score: v1 = 4/10 → v2 target = 8/10** (Phases 1–3 complete and
> verified; conditional on Phases 4–6).

---

## Changelog

**v2.0 → v2.1** — Goose HTTP server is `goose serve` (not `goose acp`, stdio-only); `GOOSE_SERVER__SECRET_KEY` auth; ADR-06 profile→port registry; watchdog mark-`failed` semantics; `storage/goose_data/**` added to `.gitignore`.

**v2.2 → v2.3 (Refactoring & Security Sprint, 2026-11-06)** — an aborted
Phase 4/5 execution had left the doc set self-contradictory (fake "verified"
checkpoints dated to a not-yet-executed Phase 6; an uncommitted `run.sh`
draft reverting the verified `hermes serve` fact to `hermes gateway`; an
enforced-but-untracked permission policy). Corrections:

- **Phases 4 and 5 downgraded to Pending** everywhere; all unsubstantiated
  "verified" claims removed (STATUS.md, phase docs, this spec).
- **`hermes serve` re-confirmed live** as the HTTP backend server
  (`hermes gateway` = messaging management, no `--port`) — the v2.2 fact
  stands; the contradicting draft was reverted.
- **ADR-04 withdrawn** (SQLite `journal_mode: delete`): the Execution Plane
  runs **natively on the host filesystem**, not on virtiofs/9p Docker mounts
  — WAL is correct there. `ensure-sqlite-modes.sh` deleted.
- **Host Launcher binds `0.0.0.0:9000`** (secret mandatory) so the
  Paperclip→launcher trigger path actually works; idle watchdog now probes
  real TCP traffic before reaping.
- **R8 hygiene gap closed**: `storage/hermes_data/**` ignored wholesale
  (auth.lock/state.db were untracked-but-unignored); `permission.yaml` is
  now the tracked tool-level policy source of truth.
- Orphaned `backoff_proxy.py` / `acp_ws_driver.py` deleted; `#6596` backoff
  deliverable re-opened.

**v2.1 → v2.2 (implementation-verified)** — every item below was validated on the host, not assumed:

| Area | v2.1 assumption | v2.2 verified fact |
|---|---|---|
| Hermes server | `hermes gateway run --port 8642` | **`hermes serve --port <p> --host 0.0.0.0`** (Hermes v0.22.7). `hermes gateway` is a *messaging* gateway (Telegram/Discord) with no `--port`. `hermes acp` exists but is stdio-only (same Risk-R9 class as `goose acp`). |
| Hermes auth | plain `API_SERVER_KEY` env header | A non-loopback bind requires Hermes's **own auth provider** (password/OAuth); `--insecure` is a no-op as of the June 2026 hardening. `API_SERVER_KEY` remains the exported secret name for future use; treat the auth-provider setup as the binding gate. |
| Goose bind/port | env vars `GOOSE_SERVER__HOST` / `GOOSE_SERVER__PORT` | goose 1.56.0 **ignores** those env vars — ports/bind are passed as **CLI flags**: `goose serve --host 0.0.0.0 --port <port>`. |
| Goose auth header | `Authorization: Bearer <key>` | **`X-Secret-Key: <GOOSE_SERVER__SECRET_KEY>`** (Bearer is rejected with 401). Validated against goose 1.56.0 `/acp`. |
| Control Plane image | `paperclip/orchestrator:latest` (illustrative) | **`ghcr.io/paperclipai/paperclip:latest`** — serves UI+API on container **:3100** (`HOST=0.0.0.0`, `PORT=3100`, `SERVE_UI=true`); external PostgreSQL via `DATABASE_URL`; Drizzle migrations apply at boot; requires `BETTER_AUTH_SECRET`. |
| Session persistence | `persistSession: false` adapter field | **No such field exists in real Paperclip.** The durable equivalent of ADR-05/#1160 is **`sessionKeyStrategy: 'run'`** (one fresh session per run). Paperclip's default `'issue'` persists sessions per issue and stays forbidden until the upstream session-ID regex fix (#1160) is validated. |
| Goose adapter in Paperclip | "REST/ACP client for Goose" | Paperclip has **no native Goose adapter**. goose serve's HTTP ACP (`/acp`, `X-Secret-Key`) is the validated durable contract; wiring lands via Paperclip's ACP/custom-adapter path. |
| Persistence schema | `tickets` / `runs` tables (illustrative) | Real Paperclip Drizzle tables: **`issues`, `heartbeat_runs`, `native_run_results`, `routine_runs`, `goals`, `companies`, …** (spec §5.4 names are illustrative). |
| Host daemons lifetime | persistent systemd units | **ADR-07 superseded systemd**: daemons are spawned on demand by the **Host Launcher Micro-API** (`launcher.py`, :9000) and torn down after a 10-minute idle timeout. systemd §5.3 is historical only. |
| Launcher reachability | bind `0.0.0.0` if container-triggered | **v2.3: the launcher binds `0.0.0.0:9000`** (secret mandatory) — container-originated triggers via `host.docker.internal` are the supported ADR-07 path. The earlier Phase-3 loopback-only topology made the "on-demand" story unreachable and was corrected in the Refactoring & Security Sprint. |
| Cross-boundary networking | firewall unspecified | **Host firewall must allow docker0** (`sudo ufw allow in on docker0`) before container→host tests can pass. |
| Adapter secret handling | secrets injected as container env | Adapter secrets are stored as **Paperclip secret references** (UI/API), never injected into the container environment. |

---

## Table of Contents

1. [Vision and Objectives](#1-vision-and-objectives)
2. [System Architecture](#2-system-architecture)
3. [Settled Architecture Decisions (ADRs)](#3-settled-architecture-decisions-adrs)
4. [Phased Implementation Plan](#4-phased-implementation-plan)
5. [Implementation References (code)](#5-implementation-references-code)
6. [Decision Matrices](#6-decision-matrices)
7. [Risk Register](#7-risk-register)
8. [Go/No-Go Validation Checklist](#8-gonogo-validation-checklist)

---

## 1. Vision and Objectives

The fundamental objective remains: reconcile the robustness of centralized orchestration with the flexibility of local execution — **without excessive software isolation, but also without security holes**. The system must be:

- **Local-first**: no mandatory external network dependency (apart from cloud LLM APIs in Phase 1);
- **Portable**: Linux, macOS, Windows/WSL2 — a single Git repository plus one local `.env` file;
- **Secure by default**: all AI-generated code is sandboxed, every destructive action is traceable;
- **Resilient**: no silent failure modes anywhere in the control loop.

### 1.1 The two v1 pitfalls (and their resolution)

| v1 Pitfall | v2 Resolution |
|---|---|
| **Docker ↔ Host topological rupture**: a container cannot `spawn` a host process via `run.sh`/`run.ps1`. | **Explicit network IPC gateway**: Hermes in HTTP server mode (`hermes serve`, port 8642), Goose in HTTP/ACP server mode (`goose serve`), with Paperclip adapters pointing at `host.docker.internal`. |
| **Illusion of globalized isolation**: `HERMES_HOME` alone does not cover Goose (Rust, XDG paths). | **Mandatory symmetric injection** of `HERMES_HOME` **and** `GOOSE_PATH_ROOT` per profile, via bootstrap wrappers. |

### 1.2 Separation of the two planes

- **Control Plane (Docker)**: Paperclip — heartbeat-based scheduling, governance, budgets, transactional state (PostgreSQL + Drizzle ORM). Generates no LLM tokens itself.
- **Execution Plane (Native host)**: Hermes (strategy, reasoning) and Goose (technical execution) — direct access to local runtimes (Node.js, Rust, Go, Python), Git, IDEs — **with** confinement of risky code execution.

---

## 2. System Architecture

### 2.1 Overview

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
             │  http://host.docker.internal:8642    (hermes serve)
             │  http://host.docker.internal:3284/acp (goose serve)
             │  Auth: Hermes auth provider · X-Secret-Key (Goose)
┌────────────▼────────────────────────────────────────────────┐
│                  EXECUTION PLANE (Native host)              │
│  ┌──────────────────────┐      ┌──────────────────────────┐ │
│  │ Host Launcher (ADR-07)│ spawns on demand:                  │
│  │ launcher.py :9000     │  Hermes (Thinkers) │ Goose (Exec.) │
│  │ idle watchdog 10 min  │  hermes serve :8642│ goose serve   │
│  │ run.sh / run.ps1      │  HERMES_HOME=...   │ GOOSE_PATH_.. │
│  └──────────────────────┘      └──────────────────────────┘ │
│             │  execute_code ──▶ patched env (no PYTHONPATH);│
│             │  ephemeral sandbox is spec Phase 3 (post-MVP) │
└─────────────────────────────────────────────────────────────┘
             │
│      Monorepo Git (bind mounts) + storage/ (persistence)    │
```

### 2.2 Control Plane — Paperclip (Docker)

- **Role**: CEO/HR of the virtual organization. Models agents as employees: issue assignment, status auditing, dependency management, deliverable validation.
- **Scheduling**: heartbeat model — agents are woken by a scheduler or on events (task assignment, comment mention); each heartbeat carries a *context packet* (company state, goals, issue history).
- **Atomicity**: optimistic locking on `checkoutRunId` (409 Conflict) — complemented by an orphaned-lock watchdog (ADR-05, §5.4).
- **Adapters**: exclusively network adapters — `hermes_gateway` (HTTP/SSE to a remote Hermes). **The `hermes_local` adapter is forbidden inside the container** (it can only spawn within its own namespace). Goose has no native adapter; goose serve's HTTP ACP is the durable contract.
- **Adapter config**: per-agent `{adapterType, adapterConfig}` objects, configured via the Paperclip UI/API; secrets are stored as **Paperclip secret references**. The repo's `control-plane/paperclip/config/adapters.json` documents the Sisyphus-side durable contract (URLs, auth headers, session strategy) — it is not read by Paperclip directly.
- **Persistence**: external PostgreSQL via `DATABASE_URL`; Drizzle migrations apply automatically at boot; bind mount to `storage/paperclip_data`.
- **Deployment facts (verified)**: image `ghcr.io/paperclipai/paperclip:latest`; container serves UI+API on **:3100** (host maps **:3000→:3100**); `NODE_ENV=production`; requires `BETTER_AUTH_SECRET`; first run is `bootstrap_pending` — creating the first company/owner is a **human onboarding step** in the UI (authenticated mode).

### 2.3 Execution Plane — Hermes (Thinkers)

- **Role**: problem decomposition, functional structuring, action planning, critical review of produced work.
- **Server mode (v2.2 corrected)**: **`hermes serve --port 8642 --host 0.0.0.0`** — resident HTTP daemon (Hermes v0.22.7).
  - ⚠️ `hermes gateway` is a **messaging** gateway (Telegram/Discord) with no `--port` flag — it is **not** the HTTP API server. Do not use it for IPC.
  - ⚠️ `hermes acp` is **stdio-only** (editor clients) — same failure class as `goose acp`. Never use it for the network daemon.
  - **Auth**: a non-loopback bind requires Hermes's **own auth provider** (password/OAuth). The historical `API_SERVER_KEY` env header and `--insecure` are no-ops in hardened builds (June 2026+).
- **Identity and memory**: frozen document-injection model at session start — `SOUL.md` (personality), `AGENTS.md`/`.hermes.md` (project conventions), `USER.md` (operator profile), `MEMORY.md` (autonomously learned knowledge). Any manual edit requires a session restart.
- **State**: fully localized under `HERMES_HOME` (YAML config, memories, `state.db` SQLite with FTS5).
- **⚠️ `execute_code`**: tool is **patched** (environment allowlist; `PYTHONPATH` removed from the inherited env) and, longer-term, redirected to a containerized sandbox. See §3.2 (ADR-02).

### 2.4 Execution Plane — Goose (Executors)

- **Role**: technical workforce — system commands, AST manipulation, refactoring, build scripts, test suites.
- **Server mode**: **`goose serve`** — the HTTP/WebSocket ACP server (Agent Client Protocol, JSON-RPC 2.0) exposing `initialize`, `session/load`, `request_permission` at the **`/acp`** endpoint.
  - ⚠️ **`goose acp` is a different command** — ACP over **stdio** (editor clients such as Zed). It cannot accept network connections. The Control Plane must target `goose serve` only.
  - **Defaults**: listens on `127.0.0.1:3284`. For this architecture the bind must be non-loopback: **`goose serve --host 0.0.0.0 --port <port>`** — goose 1.56.0 **ignores** the `GOOSE_SERVER__HOST`/`GOOSE_SERVER__PORT` env variables; flags are mandatory (ADR-06).
  - **Auth**: clients authenticate with the header **`X-Secret-Key: <GOOSE_SERVER__SECRET_KEY>`** (verified: `Authorization: Bearer` is rejected with 401). The secret is distinct from Hermes credentials; both live in `.env`.
  - **Handshake**: `initialize` with integer `protocolVersion` (a string `"1.0"` is rejected with JSON-RPC `-32602`).
- **Extensibility**: MCP (Model Context Protocol) — tool discovery without recompilation.
- **Isolation**: Goose **completely ignores** `HERMES_HOME`. Path resolution uses XDG standards (`~/.config/goose/`). **Per-profile isolation strictly requires `GOOSE_PATH_ROOT`** (validated: config, data and state incl. `sessions.db` all redirect under it).
- **Permissions**: `GOOSE_MODE` ∈ {`auto`, `smart_approve`, `approve`, `chat`}, refined by tool-permission rules (§5.7). Native sub-agents via the `delegate` tool.

### 2.5 Memory and Isolation (HERMES_HOME **and** GOOSE_PATH_ROOT)

Cognitive-context isolation is achieved through **symmetric environment-variable routing** — never through separate machines:

1. Every launched agent inherits **two** variables:
   - `HERMES_HOME=<repo>/storage/hermes_data/agent_<profile>`
   - `GOOSE_PATH_ROOT=<repo>/storage/goose_data/agent_<profile>`
2. **Injecting `GOOSE_PATH_ROOT` is mandatory** for every Goose profile. Without it, concurrent Goose instances read/write the same `~/.config/goose/config.yaml` and `sessions.db` → guaranteed state collision.
3. Each profile directory encapsulates: local working memory, allowed tools and "skills", contextual LLM configuration.
4. **SQLite**: runs natively on the host filesystem — **WAL is correct and
   must not be tampered with** (ADR-04 was withdrawn in v2.3: its
   virtiofs/9p premise does not apply to the native Execution Plane).

> **Golden rule:** *profile isolation* ≠ *execution security*. Environment variables compartmentalize identities and memories; they provide **zero protection** against arbitrary code execution (see ADR-02).

### 2.6 Portability and Synchronization

- **Git monorepo**: agent hierarchy, prompt templates, bootstrap scripts, orchestration rules — all versioned.
- **Local `.env`** (excluded from version control): API keys, secrets, ports. `ports.env` (from `ports.env.example`) declares the profile→port registry.
- **Reproducibility**: `git clone` + instantiate `.env`/`ports.env` + `./start.sh` = operational state.

### 2.7 Responsibility Table

| Layer | Component | Runtime | Primary Responsibility |
|---|---|---|---|
| Control Plane | Paperclip | Docker (`ghcr.io/paperclipai/paperclip`) | Governance, task allocation, heartbeat, budgets, status tracking |
| Control Plane | PostgreSQL | Docker | Transactional state (Drizzle ORM) |
| Execution Plane | Hermes | Native (`hermes serve`, :8642) | Strategy, analytical decomposition, architecture review |
| Execution Plane | Goose | Native (`goose serve`, HTTP/WS `:3284/acp`) | Code writing, shell commands (approval-gated) |
| Execution Plane | Host Launcher | Native Python service (:9000) | On-demand spawn via `run.sh`/`run.ps1`, idle-timeout teardown, one-button startup |
| Persistence | Monorepo + bind mounts | Native | State synchronization, skill versioning |
| Security | `smart_approve` + env allowlist | Native | MVP security baseline (sandboxing is post-MVP) |

---

## 3. Settled Architecture Decisions (ADRs)

These decisions are **settled** (status: *Accepted*). v2.2 corrects *factual* details, not the decisions themselves.

### ADR-01 — IPC: HTTP / ACP API Gateway (rejection of direct native execution)

- **Decision**: all Control Plane ↔ Execution Plane communication goes through a network channel: Hermes `hermes serve` (:8642) + Goose `goose serve` (HTTP/WS, `/acp`, JSON-RPC 2.0), targets `host.docker.internal`, auth per §2.3/§2.4.
- **Transport caution (verified)**: `goose acp` and `hermes acp` are **stdio-only**; `hermes gateway` is a messaging gateway. The HTTP daemons are `goose serve` and `hermes serve`. The §8 connectivity tests exist precisely to catch this class of error.
- **Rationale**: a container can only spawn processes within its own namespace; bind mounts share files but provide no cross-execution vector. Network-based coupling is the only viable architecture for reliable, modular, ACP/MCP-compliant distributed orchestration.
- **Rejected alternatives**:
  - *Docker-out-of-Docker* (mounted socket): privilege-escalation surface, asymmetric path/permission complexity, unresolved file-locking → **rejected**.
  - *Local SSH connector*: strong isolation but unacceptable per-heartbeat latency and key management → **fallback only**.
- **Operational consequence**: host daemons are spawned and torn down by the **Host Launcher** (ADR-07), not by persistent systemd units.

### ADR-02 — Security: human approval in MVP, ephemeral sandboxing as target, immediate RCE patch

Three measures, **all mandatory and complementary**:

1. **Emergency patch (immediate, before any deployment)** — Hermes `execute_code`:
   - Strict environment allowlist for every subprocess it spawns (CVE-2026-9368: `PYTHONPATH` module injection → Base64 exfiltration of API keys, bypassing stdout redaction).
2. **MVP phase (transitional)** — `GOOSE_MODE=smart_approve`: human control over destructive actions. Accepted cost: breaking asynchronous autonomy, tolerated while trust is calibrated.
3. **Target solution** — ephemeral container sandboxing (`docker run --rm`, Podman, gVisor) for all unverified code execution. Once deployed, a controlled return to `GOOSE_MODE=auto` coupled with Paperclip-managed token budgets.

> Environmental profile isolation (ADR-03) is retained **for memory only**; it offers no protection against RCE.

### ADR-03 — Isolation: symmetric injection of HERMES_HOME + GOOSE_PATH_ROOT

- **Decision**: bootstrap wrappers (`run.sh`/`run.ps1`) and the launcher **always and symmetrically** inject `HERMES_HOME` and `GOOSE_PATH_ROOT` per profile. No agent starts without both (hard failure).
- **Rationale**: Goose is impermeable to `HERMES_HOME`; without `GOOSE_PATH_ROOT` concurrent profiles overwrite each other's config and session DB (verified by the Phase 2 collision test).

### ADR-04 — SQLite journal modes — **WITHDRAWN (v2.3)**

- **Original decision**: any Hermes/Goose SQLite DB on a Docker volume mount is forced to `journal_mode: delete`; on native Linux filesystems WAL may remain.
- **Original rationale**: WAL on virtual mounts → `DeletedWalGenerationError`, ghost locks, neutralized agent memory.
- **Withdrawn because**: the premise never applies to this architecture — ADR-01 places the Execution Plane **natively on the host filesystem** (ext4), not on virtiofs/9p Docker mounts. The enforced `journal_mode=delete` fought the daemons' own correct default (observed: a running daemon reverted its DB to WAL), and the enforcement script could never satisfy its own acceptance criterion while any daemon was live. SQLite uses its default WAL mode; `ensure-sqlite-modes.sh` was deleted. If a future phase ever places agent state on a Docker volume mount, re-open this ADR **scoped to that mount only**.

### ADR-05 — Paperclip mitigations: session strategy + lock watchdog

| Issue | Symptom | Decision |
|---|---|---|
| **#1160** — Session ID corruption (overly permissive regex → invalid ID persisted → `--resume` crash → infinite 2-second-run loop) | Infinite loop, blocked task | **Fresh session per run** — expressed in real Paperclip as `sessionKeyStrategy: 'run'` (v2.2: the spec's historical `persistSession: false` field does not exist in the real product). Reactivation of issue-scoped sessions planned post-MVP. |
| **#3819** — Orphaned locks (`checkoutRunId` not cleared after silent failure) | Progress blocked | **Watchdog**: purge of `checkoutRunId` for runs inactive > 60 minutes (liveness semantics, mark-run-`failed` first). See §5.4. |
| **#6596** — Offline request storm (mass run creation during disconnect) | Adapter log saturation | **Exponential backoff** + suspension of run creation on `ENOTFOUND`/`ECONNREFUSED`. |

### ADR-06 — Multi-profile port registry (single URL per adapter is not enough)

- **Decision**: one server per **profile** ⇒ one **port per profile**, declared in `execution-plane/scripts/ports.env` (local copy of `ports.env.example`, git-ignored):
  - `HERMES_PORT_CEO=8642`, `GOOSE_PORT_DEV=3284`, `GOOSE_PORT_REVIEWER=3285`.
- **Consumers**: `run.sh`/`run.ps1` pass the port to the engine (Goose: `--port` CLI flag; Hermes: `--port` flag) and the Control Plane adapters target `http://host.docker.internal:<port>`.
- **Rationale**: without the registry the two-concurrent-profiles collision test cannot be constructed, and two profiles on one port = guaranteed crash-loop.

### ADR-07 — Dynamic Host Launcher Micro-API & One-Button Execution

- **Decision**: a lightweight host-side launcher (`execution-plane/scripts/launcher.py`, stdlib HTTP on `127.0.0.1:9000`) spawns agent daemons on demand via `run.sh`/`run.ps1` (`POST /launch?profile=<p>&engine=<goose|hermes>`), tears them down (`POST /shutdown?profile=<p>`), reports state (`GET /status`), and idles out daemons after 10 minutes without traffic. Root `start.sh`/`stop.sh` provide one-button startup/teardown of launcher + `docker compose up -d`.
- **Binding topology (Refactoring & Security Sprint, 2026-11-06 — supersedes the Phase-3 loopback-only topology)**: the launcher binds **`0.0.0.0:9000`** so Paperclip (inside Docker) can actually trigger daemon spawn/teardown via `host.docker.internal:9000` (`/launch`, `/shutdown`, `/touch`). The `X-Launcher-Secret` header is **mandatory** — the launcher hard-fails on startup if bound non-loopback without a configured secret. The idle watchdog probes **real TCP traffic** on the daemon's port before reaping, so a busy agent is never killed (a traffic-blind idle timer would reap active daemons, since container-side clients previously could not POST `/touch`).
- **Rationale**: permanent resident daemons for every profile waste host RAM/CPU; Dockerizing agents breaks native toolchain/GUI work. The launcher keeps daemons on demand without compromising native execution.
- **Supersedes**: §5.3 persistent systemd units (historical reference only — do not install).

---

## 4. Phased Implementation Plan

> Governing principle: **communication (IPC) and material security foundations must be consolidated BEFORE any advanced cognitive feature is deployed.**

The MVP is decomposed into six sub-phases executed by the repo's phase docs
(`docs/phases/`). Status as of this revision:

| Sub-phase | Scope | Status |
|---|---|---|
| 1 | Monorepo scaffolding, `.gitignore`, env templates | ✅ Complete (verified) |
| 2 | Execution plane daemons (`run.sh`, profiles, collision test) | ✅ Complete (verified) |
| 3 | Control plane (Paperclip + PostgreSQL), launcher, connectivity tests | ✅ Complete (verified; human bootstrap pending) |
| 4 | Security mitigations (CVE patch, smart_approve, permission rules) | ⬜ Pending (re-opened 2026-11-06) |
| 5 | Reliability (orphaned-lock watchdog, network backoff) | ⬜ Pending (re-opened 2026-11-06) |
| 6 | E2E validation & Go/No-Go | ⬜ Pending |

### Phase 1 (MVP scope, in brief)

Complete Control Plane ↔ Execution Plane pipeline, minimally secured, on cloud APIs. Out of scope: local inference, Qdrant, ephemeral sandboxing, `GOOSE_MODE=auto`, issue-scoped sessions.

**E2E exit criteria:** Paperclip healthy in Docker; task created via UI/API; CEO agent writes a technical spec; Dev agent implements it and runs tests under `GOOSE_MODE=smart_approve` **with human confirmation**; confirmation reported back to Paperclip; ticket closes. No corrupted sessions, no orphaned locks, no ghost runs.

---

## 5. Implementation References (code)

### 5.1 Monorepo tree (as built)

```
Sisyphus/
├── .env.example                      # secrets template (real .env git-ignored, R8)
├── .gitignore                        # R8 mandatory lines + hygiene
├── docker-compose.yml                # real Paperclip image + PostgreSQL 16
├── STATUS.md                         # progress tracker
├── docs/
│   ├── README.md                     # documentation index
│   ├── spec/                         # this specification
│   └── phases/                       # the six phase documents
├── control-plane/paperclip/config/
│   ├── adapters.json                 # network-only adapter contract (ADR-01)
│   └── tool_permissions.json         # permission policy (Phase 4)
├── execution-plane/
│   ├── scripts/
│   │   ├── run.sh / run.ps1          # bootstrap wrappers (ADR-03/06)
│   │   ├── launcher.py               # Host Launcher Micro-API (ADR-07)
│   │   ├── start.sh / stop.sh        # one-button startup/teardown
│   │   ├── ports.env.example         # ADR-06 registry template
│   │   └── test_container_connectivity.sh  # atomic Phase 3 test suite
│   ├── profiles/
│   │   ├── ceo/hermes_config/        # SOUL.md, AGENTS.md
│   │   ├── dev/goose_config/         # config.yaml (smart_approve)
│   │   └── reviewer/goose_config/    # config.yaml (smart_approve)
│   └── workspace/                    # agent deliverables
└── storage/
    ├── paperclip_data/               # Paperclip state (bind mount)
    ├── paperclip_pgdata/             # PostgreSQL data dir (git-ignored)
    ├── hermes_data/agent_*/          # HERMES_HOME per profile
    └── goose_data/agent_*/           # GOOSE_PATH_ROOT per profile
```

Mandatory `.gitignore` (R8 — v2.3: Hermes state ignored **wholesale** after
the sprint found auth.lock/state.db untracked-but-unignored): `.env`,
`ports.env`, `storage/hermes_data/**`, `storage/goose_data/**`,
`storage/paperclip_data/*` (except `.gitkeep`), `storage/paperclip_pgdata/`,
launcher logs, `execution-plane/workspace/*` (except `.gitkeep`) — plus
hygiene entries (`node_modules/`, `__pycache__/`, `.pytest_cache/`, `*.pyc`,
`.DS_Store`).

### 5.2 `docker-compose.yml` (Control Plane — as built, verified)

```yaml
services:
  paperclip:
    image: ghcr.io/paperclipai/paperclip:latest
    container_name: paperclip_control_plane
    restart: unless-stopped
    pids_limit: 2048            # tini is PID 1; backstop against agent forks
    stop_grace_period: 90s
    ports: ["3000:3100"]        # host :3000 → container :3100 (real contract)
    environment:
      HOST: "0.0.0.0"
      PORT: "3100"
      SERVE_UI: "true"
      NODE_ENV: production
      DATABASE_URL: postgres://paperclip:${POSTGRES_PASSWORD}@postgres:5432/paperclip
      PAPERCLIP_DEPLOYMENT_MODE: authenticated
      PAPERCLIP_DEPLOYMENT_EXPOSURE: private
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET}   # session signing secret
      # Adapter secrets are NOT injected here — they are Paperclip secret refs.
    extra_hosts: ["host.docker.internal:host-gateway"]   # required on Linux
    volumes:
      - ./storage/paperclip_data:/paperclip
    depends_on:
      postgres: { condition: service_healthy }
  postgres:
    image: postgres:16
    container_name: paperclip_postgres
    environment:
      POSTGRES_USER: paperclip
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: paperclip
    ports: ["127.0.0.1:5432:5432"]
    volumes: [ "./storage/paperclip_pgdata:/var/lib/postgresql/data" ]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U paperclip -d paperclip"], interval: 5s, retries: 10 }
```

Required `.env` keys: `POSTGRES_PASSWORD`, `BETTER_AUTH_SECRET`, `PAPERCLIP_PUBLIC_URL`, plus the Execution Plane secrets (`GOOSE_SERVER__SECRET_KEY`, `LAUNCHER_SECRET`, LLM keys).

### 5.3 Host daemon lifecycle — Host Launcher (ADR-07; systemd §historical)

`launcher.py` (stdlib only): `GET /status`, `POST /launch?profile=<p>&engine=<goose|hermes>`, `POST /shutdown?profile=<p>`, `POST /touch?profile=<p>`. It resolves the profile port from the ADR-06 registry, executes `run.sh <profile> <engine>` in the background, and polls liveness + idle timeout (10 min default). Secret header `X-Launcher-Secret` is required whenever the bind is non-loopback.

> Persistent systemd units (`goose-serve@.service`, `hermes-gateway@.service`)
> are **deprecated by ADR-07** and were removed from the repo.

### 5.4 Orphaned-lock watchdog (Issue #3819)

> **Schema caution**: the SQL below is illustrative. Real Paperclip Drizzle
> tables discovered in Phase 3: `issues` (≈ "tickets"), `heartbeat_runs` /
> `native_run_results` (≈ "runs"), plus `goals`, `companies`. Validate column
> names against the live schema before deploying.

⚠️ **Liveness semantics (R10)**: a 60-minute-old lock is **not** automatically orphaned. The purge must (a) check run liveness (`last_activity_at`, not start time), and (b) mark the stale run **`failed`** first — only watchdog-marked failures release their ticket's lock (prevents duplicate execution).

```sql
UPDATE runs SET status='failed', finished_at=now(),
       error='watchdog: orphaned lock — no activity for 60+ minutes'
WHERE finished_at IS NULL AND started_at < now()-interval '60 minutes'
  AND last_activity_at < now()-interval '60 minutes';

UPDATE tickets SET checkout_run_id=NULL, status='ready'
WHERE checkout_run_id IN (
  SELECT id FROM runs WHERE status='failed' AND error LIKE 'watchdog:%');
```

Implementation: `execution-plane/scripts/watchdog-locks.sh` (+ `--dry-run`) on a 10-minute timer, or a priority API endpoint in Paperclip — either is acceptable.

### 5.5 `execute_code` patch (CVE-2026-9368)

```python
_ENV_ALLOWLIST = {"PATH", "HOME", "LANG", "TMPDIR", "VIRTUAL_ENV"}

def _sanitized_env() -> dict:
    """Strict allowlist: neutralizes PYTHONPATH and any module-injection
    vector (CVE-2026-9368). Applied to EVERY subprocess spawn."""
    env = {k: v for k, v in os.environ.items() if k in _ENV_ALLOWLIST}
    env.pop("PYTHONPATH", None)   # stripped — never re-added (CVE-2026-9368)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env

# subprocess.Popen(..., env=_sanitized_env(), ...)
```

> **Contract:** `PYTHONPATH` is **removed** from the child environment — not
> emptied, not re-added. (An earlier revision of this snippet popped the key
> and then re-assigned it to `""`, contradicting itself.) **Known deviation in
> the deployed build (Hermes v0.22.7):** its `_build_child_env` re-injects a
> *trusted* `PYTHONPATH` (`/tmp/stage:/opt/hermes-agent`) after the scrub;
> attacker-controlled entries are stripped. Accepted as long as the trusted
> entries are verified non-attacker-controlled.

### 5.6 `run.sh` (bootstrap wrapper — as built, verified)

Key behaviours (full source: `execution-plane/scripts/run.sh`):

- `git pull --rebase` tolerated to fail (offline host).
- Loads `.env` + `ports.env`; **hard-fails** if either is missing.
- **Symmetric injection (ADR-03)**: exports both `HERMES_HOME` and
  `GOOSE_PATH_ROOT` per profile, `mkdir -p` both, hard-fails if unset.
- Seeds the profile config (`config.yaml` **and** `permission.yaml` — the
  tracked tool-level policy) into the engine's isolated root **without
  overwriting** existing files.
- ADR-06 port lookup from the registry (`HERMES_PORT_CEO`, `GOOSE_PORT_DEV`, …).
- Engines (v2.2 verified commands):
  - `hermes serve --port <HERMES_PORT_*> --host 0.0.0.0`
  - `goose serve --host 0.0.0.0 --port <GOOSE_PORT_*>` (flags — env vars are
    ignored by goose 1.56.0; `GOOSE_MODE=smart_approve` exported for MVP).

`run.ps1` mirrors this in PowerShell (logic identical; syntax-checked
equivalent — no pwsh on the reference host, so flagged as untested).

### 5.7 Tool-permission policy (`tool_permissions.json`)

> **Schema caution (updated v2.3)**: Goose's native permission mechanism is
> tool-name-level only — the tracked source of truth for it is
> `execution-plane/profiles/<p>/goose_config/permission.yaml` (seeded by
> `run.sh`/`run.ps1`). The pattern rules in
> `control-plane/paperclip/config/tool_permissions.json` are the durable
> policy **intent**; they cannot be enforced by goose natively and require
> the wrapper layer (see that file's `enforcement_notes`). The **policy
> content** is durable regardless of format: block
> `.env`/`secrets/`/`id_rsa`/`.ssh/` and `rm -rf /`; require approval for
> force-push to `main`; allow test runners (`pytest`, `npm test`,
> `cargo test`).

```json
{
  "default_mode": "smart_approve",
  "rules": [
    { "pattern": ".*(\\.env|secrets/|id_rsa|\\.ssh/).*", "action": "block" },
    { "pattern": "^rm\\s+-rf\\s+/", "action": "block" },
    { "pattern": "^git push(--force)?\\s+.*main$", "action": "require_approval" },
    { "pattern": "^pytest|^npm test|^cargo test", "action": "allow" }
  ]
}
```

---

## 6. Decision Matrices

### Matrix 1 — IPC Protocols (decision: A)

| Alternative | Advantages | Drawbacks | Verdict |
|---|---|---|---|
| **A. HTTP/REST/ACP API Gateway** ✅ | Natively crosses the Docker barrier; SSE streaming; ACP/MCP-compliant | Requires launcher lifecycle management; non-loopback binds + auth + firewall rules all mandatory | **ADOPTED** (validated E2E in Phase 3) |
| B. Unix sockets / Docker-out-of-Docker | Full control | Privilege-escalation surface; file-locking issues | **REJECTED** |
| C. Local SSH connector | Strong isolation | Per-heartbeat latency; key management | **FALLBACK ONLY** |

### Matrix 2 — Security / Sandboxing

| Strategy | Verdict |
|---|---|
| Env allowlist patch (`PYTHONPATH`) | **MANDATORY** (immediate; Phase 4 of the sub-phase plan) |
| `GOOSE_MODE=smart_approve` (MVP) | **MANDATORY** (transitional; sandbox is post-MVP) |
| Ephemeral container sandboxing | **TARGET** (spec Phase 3 — post-MVP); after which `GOOSE_MODE=auto` + Paperclip token budgets may return |

---

## 7. Risk Register

| # | Risk | Severity | Mitigation | Status |
|---|---|---|---|---|
| R1 | RCE via `PYTHONPATH` (CVE-2026-9368) | **Critical** | Env allowlist patch + (post-MVP) sandbox + key rotation | Patch pending (Phase 4) |
| R2 | Infinite session-ID loop (#1160) | High | Fresh session per run (`sessionKeyStrategy: 'run'`) | ✅ Contract fixed in Phase 3 |
| R3 | Orphaned PostgreSQL locks (#3819) | High | Watchdog with liveness semantics | Phase 5 |
| R4 | Multi-profile state collision | High | Symmetric `GOOSE_PATH_ROOT` (ADR-03) | ✅ Verified Phase 2 |
| R5 | WAL on virtual mounts (`DeletedWalGenerationError`) | Medium | ~~`journal_mode: delete`~~ **ADR-04 withdrawn (v2.3)** — premise N/A: Execution Plane is native, WAL correct | Withdrawn |
| R6 | Offline run storm (#6596) | High | Exponential backoff + run-creation suspension | Phase 5 |
| R7 | `GOOSE_MODE=auto` without sandbox | **Critical** | `smart_approve` mandatory at MVP | ✅ Set in profiles; verified Phase 4 |
| R8 | Secrets leak into Git | **Critical** | `.gitignore` coverage + negative tests | ✅ Verified Phases 1–3 |
| R9 | Wrong command / localhost bind → daemon unreachable from container | High | `goose serve`/`hermes serve` + `--host 0.0.0.0` + in-container curl tests | ✅ Verified Phase 3 |
| R10 | Watchdog kills legitimate long runs | High | Liveness check on activity, mark-`failed`-first | Phase 5 |
| R11 | Host Launcher failure / port collision (:9000) | Medium | Fallback to direct `run.sh` execution; port from `ports.env` | Designed; Phase 6 verifies |

---

## 8. Go/No-Go Validation Checklist

**Phase 1 (MVP) can only be declared complete if every item passes.** Detailed
procedures live in `docs/phases/06-e2e-validation.md`.

- [x] Container→host connectivity: goose `/acp` answers `initialize` from
      **inside** the container with `X-Secret-Key`; **401 without**.
      (Validated Phase 3, goose 1.56.0.)
- [ ] Hermes `:8642` answers from inside the container with valid auth
      (Hermes auth provider — setup lands with agent wiring).
- [x] Two Goose profiles on distinct ports (ADR-06), launched **concurrently**,
      zero cross-writes to configs (Phase 2 collision test).
- [ ] `execute_code` runs with `PYTHONPATH` absent (trusted re-injection per
      §5.5 allowed); the injection-shaped import fails from within it
      (Phase 4).
- [x] Fresh-session-per-run contract verified in the adapter configuration
      (`sessionKeyStrategy: 'run'`; the historical `persistSession` field
      does not exist in real Paperclip).
- [ ] Watchdog purges a stale-but-idle test lock (see Phase 5 procedure).
- [ ] Full E2E CEO → Dev → `pytest` → Paperclip confirmation, no ghost runs.
- [ ] Tool-permission policy blocks `.env`/`secrets/` access (negative test).
- [ ] Paperclip smoke ticket created via UI/API (after the one-time human
      onboarding at `http://localhost:3000`).

---

## Appendix A — Audit Finding → v2 Mapping

| Audit Finding | v2 Section | Status |
|---|---|---|
| Docker ↔ Host IPC gap | ADR-01, §2.1, §5.2 | ✅ Fixed (Phase 3 verified) |
| CVE-2026-9368 / RCE | ADR-02, §5.5 | Phase 4 re-opened — env-scrub present in the installed build; acceptance re-verification required |
| Goose ignores `HERMES_HOME` | ADR-03, §2.5 | ✅ Fixed (Phase 2 verified) |
| `DeletedWalGenerationError` | ADR-04 | Withdrawn with ADR-04 (v2.3) — premise N/A |
| Issue #1160 (session ID) | ADR-05 | ✅ Contract fixed (session strategy) |
| Issue #3819 (orphaned locks) | ADR-05, §5.4 | Pending (Phase 5) |
| Issue #6596 (run storm) | ADR-05 | Pending (Phase 5) |
| `goose acp` is stdio; server is `goose serve` | §2.4, ADR-01, R9 | ✅ Fixed (Phase 2/3 verified) |
| `hermes gateway` is not the HTTP server | §2.3, ADR-01 | ✅ Fixed (v2.2 — `hermes serve`) |
| No per-profile port mapping | ADR-06 | ✅ Fixed (Phase 2 verified) |
| Watchdog liveness semantics | §5.4, R10 | Pending (Phase 5 — re-opened; script exists but unverified) |
| Unverified env-var/schema names | §5.2, §5.4, §5.7 | ✅ Validated against real Paperclip (Phase 3) |

## Appendix B — Primary Sources

1. Paperclip — `paperclipai/paperclip` repo + docs.paperclip.ing (adapters, deployment, compose contract)
2. Goose — Configuration Files (goose-docs.ai); installed goose 1.56.0 behaviour
3. Hermes — installed v0.22.7 CLI behaviour (`hermes serve` / `hermes gateway` / `hermes acp`)
4. Paperclip #1160 (session ID), #3819 (orphaned locks), #6596 (run storm)
5. Goose #6642 (goosed to ACP-over-HTTP); SQLite Issue #109740 (WAL on virtual mounts)
6. CVE-2026-9368 — Hermes `execute_code` `PYTHONPATH` RCE
