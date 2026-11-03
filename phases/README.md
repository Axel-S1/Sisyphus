# Phase Documentation — Path to MVP

This directory contains the **execution plan to reach the MVP** of the
"Local-First Multi-Agent System" (Paperclip · Hermes · Goose).

Source of truth: the architecture spec in the repository root
(`Multi-Agents Architecture (Paperclip, Goose, Hermes) v2 — Post-Audit Review.md`,
v2.1). The MVP is the spec's **Phase 1**; it is decomposed here into
**6 sequential sub-phases**, each sized for one autonomous agent run.

---

## Execution order (strict)

| # | Phase doc | Scope | Depends on |
|---|-----------|-------|------------|
| 1 | [`01-monorepo-scaffolding.md`](01-monorepo-scaffolding.md) | Repo tree, `.gitignore`, `.env.example`, `ports.env.example` (ADR-06) | — |
| 2 | [`02-execution-plane-daemons.md`](02-execution-plane-daemons.md) | `run.sh`/`run.ps1`, Hermes gateway + `goose serve` daemons, systemd units, profiles | 01 |
| 3 | [`03-control-plane-paperclip.md`](03-control-plane-paperclip.md) | `docker-compose.yml`, PostgreSQL/Drizzle, `adapters.json` (`persistSession: false`), ACP client for Goose | 01, 02 |
| 4 | [`04-security-mitigations.md`](04-security-mitigations.md) | `PYTHONPATH` patch (CVE-2026-9368), `GOOSE_MODE=smart_approve`, `tool_permissions.json`, SQLite `journal_mode: delete` | 02 |
| 5 | [`05-reliability-watchdog.md`](05-reliability-watchdog.md) | Orphaned-lock watchdog (#3819, liveness semantics), exponential backoff (#6596) | 03 |
| 6 | [`06-e2e-validation.md`](06-e2e-validation.md) | Go/No-Go checklist execution, full E2E CEO → Dev → pytest → Paperclip | all |

**MVP is declared complete only when every checkbox in `06-e2e-validation.md`
passes.** Nothing in the spec's Phases 2–5 (RAG, sandboxing, local inference)
is in MVP scope — explicitly out of scope: ephemeral sandboxing (Phase 3 of
spec), Qdrant, local Ollama, `GOOSE_MODE=auto`, `persistSession: true`.

---

## Instructions for the executing agent

1. **Read the phase doc end-to-end before writing any code.**
2. **Do exactly one phase per run.** Do not jump ahead; later phases assume
   earlier artifacts exist.
3. **Verify each acceptance criterion yourself** with the commands in the
   doc's "Acceptance criteria" section before declaring the phase done.
4. **Never modify settled decisions.** The ADRs in the spec (§3) are final.
   If an instruction in a phase doc conflicts with the spec, the spec wins —
   report the conflict in your final summary instead of improvising.
5. **⚠️ Schema caution (from the spec):** several names are flagged as
   *illustrative* — env-var names for adapter URLs (ADR-06), table/column
   names in the watchdog SQL (§5.4), and the `tool_permissions.json` schema
   (§5.7). When you encounter one, **validate against the actual installed
   component** (Paperclip's `adapters.json` schema, Drizzle schema, installed
   Goose build) and adapt, keeping the *durable contract* (URLs, secrets,
   policy intent) intact.
6. **Secrets hygiene (R8):** never commit `.env`, `ports.env`,
   `storage/goose_data/**`, or `storage/hermes_data/**/sessions|logs/`.
   If you notice any of these in Git, stop and fix immediately.
7. **Never use `goose acp`** for the network server — it is stdio-only.
   The HTTP/WS ACP server is `goose serve` (default `127.0.0.1:3284`,
   endpoint `/acp`, auth `GOOSE_SERVER__SECRET_KEY`). This single mistake
   is Risk R9 and causes a silently dead daemon.
8. **Never bind `goose serve` to localhost** for this architecture:
   `GOOSE_SERVER__HOST=0.0.0.0` is mandatory (localhost silently refuses
   traffic from `host.docker.internal`).
9. When a phase has multiple independent tasks, prefer parallel
   exploration/implementation, but never have two tasks write the same file.
10. Finish your run with: a summary of what was built, all acceptance
    criteria results (pass/fail + evidence), and any deviations or open
    questions for the next phase.
