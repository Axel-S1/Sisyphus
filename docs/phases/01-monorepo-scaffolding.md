# Phase 1/6 — Monorepo Scaffolding — **Implementation Record** ✅

> Status: **Complete** (commits `7fa1fda`, `52f138e`). Executed 2026-11-03;
> verified against the spec (ADR-06, §5.1, R8). Phases 01–03 are kept as
> implementation records so later phases know exactly what exists and why;
> forward-looking plans live in `04`–`06`.

## What was built

### Directory tree (as it exists now)

```
./
├── .env.example                     # secrets/keys template (R8)
├── .gitignore                       # R8-mandated ignores + hygiene
├── docker-compose.yml               # (realized in Phase 3)
├── STATUS.md                        # progress tracker
├── control-plane/paperclip/config/
│   ├── adapters.json                # (realized in Phase 3)
│   └── tool_permissions.json        # placeholder {} — filled in Phase 4
├── execution-plane/
│   ├── scripts/                     # run.sh, run.ps1, launcher.py, start/stop.sh,
│   │                                # ports.env(.example), test_container_connectivity.sh
│   ├── profiles/
│   │   ├── ceo/hermes_config/       # SOUL.md, AGENTS.md
│   │   ├── dev/goose_config/        # config.yaml
│   │   └── reviewer/goose_config/   # config.yaml
│   └── workspace/
├── storage/
│   ├── paperclip_data/              # (+ paperclip_pgdata/, git-ignored)
│   ├── hermes_data/agent_ceo, agent_dev
│   └── goose_data/agent_dev, agent_reviewer
└── docs/                            # spec + phases (this doc set)
```

Note: the `reviewer` profile exists in storage for the ADR-06 collision test
(two Goose profiles); only `ceo` and `dev` participate in the MVP E2E.

### `.gitignore` (R8 — validated with negative tests)

Covers all spec-mandated paths **plus** the runtime paths identified during
execution: `storage/paperclip_pgdata/` (Postgres data dir), launcher runtime
logs (`storage/launcher*.log`), and `.gitkeep` negations so placeholder dirs
stay tracked:

```
.env
ports.env
storage/hermes_data/**/sessions/
storage/hermes_data/**/logs/
storage/goose_data/**
!storage/goose_data/**/
!storage/goose_data/**/.gitkeep
storage/paperclip_data/*
!storage/paperclip_data/.gitkeep
storage/paperclip_pgdata/
storage/launcher*.log
execution-plane/workspace/*
!execution-plane/workspace/.gitkeep
```

### `.env.example` (secrets template)

- Cloud LLM keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
- Host Launcher (ADR-07): `LAUNCHER_HOST`, `LAUNCHER_PORT`, `LAUNCHER_SECRET`
- PostgreSQL (Phase 3): `POSTGRES_PASSWORD`
- Paperclip bootstrap (Phase 3): `BETTER_AUTH_SECRET`, `PAPERCLIP_PUBLIC_URL`
- Daemon auth — **distinct secrets**: `API_SERVER_KEY` (Hermes),
  `GOOSE_SERVER__SECRET_KEY` (goose serve)
- Ports pointer → `execution-plane/scripts/ports.env`

### `execution-plane/scripts/ports.env.example` (ADR-06)

```
HERMES_PORT_CEO=8642
GOOSE_PORT_DEV=3284
GOOSE_PORT_REVIEWER=3285
```

## Verification evidence

- [x] Full tree exists; placeholder dirs tracked via `.gitkeep`.
- [x] `git check-ignore -v` confirms `.env`, `ports.env`, goose data, Paperclip
      data and pgdata are all ignored (negative test for R8).
- [x] `API_SERVER_KEY` and `GOOSE_SERVER__SECRET_KEY` documented as separate
      secrets (spec §2.4).
- [x] No secrets in the initial commit (manual review of the tree).

## Deviations from the original plan

| Plan | As-built | Reason |
|---|---|---|
| `docker-compose.yml` placeholder named in Phase 1 | Realized in Phase 3 with the real image contract | Phase sequencing |
| `tool_permissions.json` placeholder `{}` | Still `{}` — Phase 4 | Intentional (schema caution §5.7) |
| `.gitignore` "six lines" | Extended set (pgdata, launcher logs, negations) | Phases 2–3 identified extra runtime paths |

## Outputs consumed by later phases

Phase 2 builds `run.sh`/`run.ps1` and profiles on this tree, sourcing
`ports.env` from the template; Phase 3 adds `launcher.py`, `start.sh`/`stop.sh`,
the real compose file, and `adapters.json`; Phase 4 fills `tool_permissions.json`.
