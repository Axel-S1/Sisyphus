# Phase 1/6 — Monorepo Scaffolding

> Spec reference: §5.1 (monorepo tree + mandatory `.gitignore`), ADR-06
> (profile→port registry), §2.6 (portability).
> Depends on: nothing. This is the first phase.

## Objective

Create the complete monorepo skeleton of the `local-first-agents` project so
that all later phases have their target files and directories. Nothing here
needs running daemons or containers.

## Context you need

- Two planes: **Control Plane** (Paperclip, Dockerized) and **Execution
  Plane** (Hermes + Goose, native host, HTTP daemons).
- Per-profile isolation is achieved with two env vars injected symmetrically
  (ADR-03): `HERMES_HOME` and `GOOSE_PATH_ROOT`.
- One server per profile ⇒ one port per profile, declared in a git-tracked
  template `ports.env.example` (ADR-06). Real secrets/ports go into local
  `ports.env` and `.env` (never committed).
- Working directory of this project: the repository root (this dir).

## Tasks

### 1. Create the directory tree

Exactly this structure (create `.gitkeep` where a dir must exist despite
being git-ignored):

```
./
├── .env.example
├── .gitignore
├── docker-compose.yml            (placeholder in this phase; real one in Phase 3)
├── control-plane/
│   └── paperclip/
│       └── config/
│           ├── adapters.json             (placeholder `{}`; filled in Phase 3)
│           └── tool_permissions.json     (placeholder `{}`; filled in Phase 4)
├── execution-plane/
│   ├── scripts/
│   │   ├── ports.env.example
│   │   └── systemd/                      (units added in Phase 2)
│   ├── profiles/
│   │   ├── ceo/
│   │   │   └── hermes_config/            (.gitkeep)
│   │   ├── dev/
│   │   │   └── goose_config/             (.gitkeep)
│   │   └── reviewer/
│   │       └── goose_config/             (.gitkeep)
│   └── workspace/
│       └── .gitkeep
├── storage/
│   ├── paperclip_data/.gitkeep
│   ├── hermes_data/
│   │   ├── agent_ceo/.gitkeep
│   │   └── agent_dev/.gitkeep
│   └── goose_data/
│       ├── agent_dev/.gitkeep
│       └── agent_reviewer/.gitkeep
└── docs/
    └── (this phases/ doc lives at repo root — keep it where it is)
```

Note: `reviewer` profile exists in storage (ADR-06 collision test needs two
Goose profiles: `dev` and `reviewer`) but only `ceo` and `dev` are wired in
the MVP E2E.

### 2. Write `.gitignore` (mandatory content — R8)

```
.env
ports.env
storage/hermes_data/**/sessions/
storage/hermes_data/**/logs/
storage/goose_data/**
storage/paperclip_data/
execution-plane/workspace/*
!execution-plane/workspace/.gitkeep
```

⚠️ `storage/goose_data/**` is non-negotiable: it contains `secrets.yaml`
(plaintext) and `sessions.db`. Also add the usual hygiene entries
(`node_modules/`, `__pycache__/`, `*.pyc`, `.DS_Store`).

### 3. Write `.env.example`

This is the template users copy to `.env`. Include exactly:

```bash
# ── Cloud LLM keys (Phase 1 MVP runs on cloud APIs) ──────────────
ANTHROPIC_API_KEY=
OPENAI_API_KEY=

# ── Daemon auth (Hermes gateway + Goose serve) — MUST be distinct ─
API_SERVER_KEY=            # Hermes gateway auth (:8642)
GOOSE_SERVER__SECRET_KEY=  # goose serve auth (HTTP/WS ACP /acp)

# ── Ports for locally-running daemons (see execution-plane/scripts/ports.env) ─
HERMES_PORT_CEo=8642
GOOSE_PORT_DEV=3284
```

### 4. Write `execution-plane/scripts/ports.env.example` (ADR-06)

```bash
# Profile → port registry (ADR-06). Copied to ports.env locally; consumed by
# systemd units, run.sh/run.ps1, and Paperclip's adapters.json.
# One port per profile — two profiles on one port = guaranteed crash-loop.
HERMES_PORT_CEo=8642
GOOSE_PORT_DEV=3284
GOOSE_PORT_REVIEWER=3285
```

### 5. Init Git and make the first commit

`git init` (if not already a repo), stage everything, commit with a message
like `phase 1: monorepo scaffolding`. Then verify no ignored file is tracked
(see acceptance criteria).

## Acceptance criteria (verify all before declaring done)

- [ ] The full tree above exists (`tree -a` output matches).
- [ ] `.gitignore` contains all six spec-mandated lines.
- [ ] `git status` is clean after creating a dummy `.env`,
      `ports.env`, and a file inside `storage/goose_data/agent_dev/` —
      i.e. none of them appear as untracked (negative test for R8).
- [ ] `git check-ignore -v storage/goose_data/agent_dev/sessions.db` returns
      a match.
- [ ] `.env.example` contains both `API_SERVER_KEY` and
      `GOOSE_SERVER__SECRET_KEY` as **separate** secrets.
- [ ] First commit exists and contains no secrets.

## Common pitfalls

- Forgetting the `!execution-plane/workspace/.gitkeep` negation line.
- Committing `ports.env` instead of only the example template.
- Using the same value for `API_SERVER_KEY` and `GOOSE_SERVER__SECRET_KEY`
  in examples — they must be distinct secrets (spec §2.4).

## Outputs for next phase

Phase 2 builds `execution-plane/scripts/run.sh`, `run.ps1`, watchdog stub and
systemd units on top of this tree; it will source `ports.env` created from
the template written here.
