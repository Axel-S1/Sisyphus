# Phase 3/6 — Control Plane (Paperclip in Docker) — **AS-BUILT RECORD** ✅

> Status: **Complete** (commits `2c55237`→`c3224d2`, `67aba3f`, `de6a38a`).
> Executed 2026-11-04 against **real Paperclip** (`ghcr.io/paperclipai/paperclip:latest`).
> Spec reference: §2.2, ADR-01 (network IPC only), ADR-05 (#1160), ADR-06,
> §5.2 (compose), ADR-07 (Host Launcher).

## What was built

### 1. Host Launcher Micro-API (ADR-07) — `execution-plane/scripts/launcher.py`

- stdlib-only HTTP server, default bind `127.0.0.1:9000` (loopback-only is
  **by design** — verified in the connectivity tests that container-originated
  triggers to :9000 are refused; Paperclip talks to the adapters directly).
- Endpoints (verified):
  - `GET /status` — registry + liveness of managed daemons
  - `POST /launch?profile=<p>&engine=<goose|hermes>` — spawns via `run.sh`,
    idempotent (port-checked); requires `X-Launcher-Secret` when a secret is
    configured
  - `POST /shutdown?profile=<p>` — graceful stop (SIGTERM→SIGKILL)
  - `POST /touch?profile=<p>` — idle reset
- **Idle watchdog**: daemons idle > `--idle-timeout` (default 600 s) are shut
  down, releasing host RAM/CPU.
- `start.sh` / `stop.sh` — one-button control: verify `.env`/`ports.env`,
  launch the launcher, `docker compose up -d` / `down`, readiness banner.

### 2. `docker-compose.yml` (real Paperclip contract)

- **Image**: `ghcr.io/paperclipai/paperclip:latest` (the spec's historical
  `paperclip/orchestrator:latest` does not exist).
- Container serves UI+API on **:3100** (`HOST=0.0.0.0`, `PORT=3100`,
  `SERVE_UI=true`); host maps **:3000→:3100** (spec §5.2 contract kept).
- **External PostgreSQL** (`postgres:16`, `pg_isready` healthcheck) via
  `DATABASE_URL`; **Drizzle migrations apply automatically at boot**.
- `BETTER_AUTH_SECRET` required (session signing; generated into `.env`).
- `extra_hosts: ["host.docker.internal:host-gateway"]` (Linux, R9).
- Adapter secrets are **not** injected as container env — they are stored as
  Paperclip secret references via UI/API (least exposure).
- Volumes: `./storage/paperclip_data:/paperclip`; Postgres data dir
  `./storage/paperclip_pgdata` (git-ignored).

### 3. `control-plane/paperclip/config/adapters.json` (durable contract doc)

Documents the network-only adapter set (ADR-01: `hermes_local` forbidden in
the container) with the **real-schema mapping** discovered during this phase:

| Sisyphus adapter | Target | Auth | Real-schema equivalent |
|---|---|---|---|
| `hermes_ceo` | `http://host.docker.internal:8642` | Hermes auth provider (API_SERVER_KEY named for compat) | `adapterType: hermes_gateway`, `apiBaseUrl`, `apiKey` as secret_ref, **`sessionKeyStrategy: 'run'`**, `dangerouslyAllowInsecureRemoteHttp: true` (dev-only escape hatch for non-loopback HTTP) |
| `goose_dev` | `http://host.docker.internal:3284/acp` | `X-Secret-Key` (Bearer rejected — verified) | Paperclip has **no native goose adapter**; ACP route is the validated durable contract |
| `goose_reviewer` | `http://host.docker.internal:3285/acp` | `X-Secret-Key` | same |

ADR-05/#1160: the spec's historical `persistSession: false` field does **not
exist** in real Paperclip — the durable equivalent is
**`sessionKeyStrategy: 'run'`** (one fresh session per run). The default
`'issue'` strategy persists sessions per issue and stays forbidden until the
upstream session-ID regex fix is validated.

### 4. Atomic connectivity test suite

`execution-plane/scripts/test_container_connectivity.sh` — one invocation:
start launcher → spawn daemons via the launcher → run the in-container curl
tests → teardown **only via the launcher's shutdown endpoints** (never a broad
`pkill goose` — the operator's own desktop goose session also runs `goose serve`
and must survive).

## Verification evidence (in-container — the Go/No-Go heart)

After `sudo ufw allow in on docker0` (the host firewall was blocking docker0
ingress — this was the last blocker):

| Test | Result |
|---|---|
| Launcher `/status` via host | ✅ registry + daemon tracking |
| `POST /launch` dev + reviewer (`X-Launcher-Secret`) | ✅ PIDs spawned via `run.sh` |
| Container → goose dev `/acp`, **no secret** | ✅ **401** (auth enforced) |
| Container → goose dev `/acp`, **with secret** | ✅ full ACP `initialize` handshake (goose 1.56.0 capabilities) |
| Container → goose reviewer `/acp`, with secret | ✅ full handshake |
| Container → launcher :9000 | ✅ refused (`000`) — by design, loopback-only |
| Teardown via launcher endpoints | ✅ clean stop, registry empty |

Drizzle/persistence check:

- [x] `docker compose up -d` brings up Paperclip + PostgreSQL; both healthy.
- [x] Paperclip web/API answers on host :3000 (HTTP 200); container health
      endpoint reports `status: ok`, `deploymentMode: authenticated`.
- [x] Drizzle migrations applied at boot — real tables exist: `issues`,
      `heartbeat_runs`, `routine_runs`, `goals`, `companies`, … (the spec's
      `tickets`/`runs` names were illustrative).

Deferred (human step, by design):

- [ ] **Smoke ticket** — Paperclip starts in `authenticated` mode with
      `bootstrap_pending`; complete the one-time first-run onboarding at
      <http://localhost:3000> (company + owner account), then create the
      smoke ticket as part of Phase 6 E2E.

## Deviations from the original sketch

| Sketch | As-built | Reason |
|---|---|---|
| `paperclip/orchestrator:latest`, :3000→:3000, `STORAGE_PATH=/app/storage` | `ghcr.io/paperclipai/paperclip:latest`, :3000→:3100, `PAPERCLIP_HOME=/paperclip` | Real upstream image contract (docs.paperclip.ing) |
| `persistSession: false` adapter field | `sessionKeyStrategy: 'run'` | Field does not exist in real Paperclip (ADR-05 durable intent kept) |
| `API_SERVER_KEY`/`GOOSE_SERVER__SECRET_KEY` as container env | Paperclip secret references via UI/API | Least exposure; verified real adapter config surface |
| Launcher triggered from container | Launcher loopback-only, host-side | Verified topology: Paperclip talks to adapters directly |
| Goose auth `Authorization: Bearer` | `X-Secret-Key` header | 401 with Bearer (verified against goose 1.56.0) |
| ACP `protocolVersion: "1.0"` string | integer `1` | JSON-RPC error `expected u16` from goose ACP (verified) |
| Host firewall unspecified | `ufw allow in on docker0` required | docker0 ingress was blocked → all cross-boundary tests failed until fixed |

## Outputs for next phase

Phase 4 hardens security on the running daemons — keep the container running
for the negative permission tests. Verified env facts for Phase 4 are
collected in its doc.
