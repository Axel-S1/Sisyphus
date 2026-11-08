# Sisyphus — Documentation

Local-first multi-agent system (Paperclip · Hermes · Goose).

| Document | Purpose |
|---|---|
| [`spec/architecture-spec.md`](spec/architecture-spec.md) | **Source of truth.** Architecture spec v2.4. ADRs, risks, Go/No-Go checklist. Settled decisions live here — phase docs must not contradict it. |
| [`phases/README.md`](phases/README.md) | Execution plan: the six sub-phases that deliver the MVP, their order, dependencies, and current status. |
| [`phases/01…06-*.md`](phases/) | One document per phase. Completed phases are written as **as-built records** (what was built, verification evidence, deviations). Pending phases are **forward-looking plans** (tasks, acceptance criteria). |
| [`phases/07-state-sync-adr08.md`](phases/07-state-sync-adr08.md) | **ADR-08 addendum (as-built)** — multi-machine state sync executed out of sequence after Phase 3; includes the clean-slate E2E validation evidence. |
| [`../STATUS.md`](../STATUS.md) | Progress tracker: phase status, verified facts, blockers. |

## Conventions for phase execution

1. Read the phase doc end-to-end before writing code; do exactly one phase per run.
2. Verify every acceptance criterion yourself before declaring the phase done.
3. **The spec wins.** If a phase doc conflicts with the spec (ADR decisions), the spec governs — report the conflict rather than improvising.
4. **Schema caution:** names flagged *illustrative* (env vars, table names, JSON schemas) must be validated against the installed component before use; the durable contract (URLs, secrets, policy intent) survives adaptation.
5. **Secrets hygiene (R8):** never commit `.env`, `ports.env`, or anything under `storage/` holding agent state. Verify with negative tests.
6. Never use stdio-only commands (`goose acp`, `hermes acp`) or messaging gateways (`hermes gateway`) as network daemons — Risk R9.
7. Finish each run with: what was built, acceptance-criteria evidence, deviations, open questions.

## Completion state (for new readers)

Phases 1–3 **and the ADR-08 state-sync addendum** are complete and verified
(see each phase's as-built record — including
[`phases/07-state-sync-adr08.md`](phases/07-state-sync-adr08.md) — and
`STATUS.md`). The ADR-08 tooling was proven by a full clean-slate
purge-and-rebirth cycle (2026-11-08). Remaining: Phase 4 (security baseline),
5 (reliability), 6 (E2E/Go-No-Go). One human step is pending: Paperclip
first-run onboarding at <http://localhost:3000> (company + owner account),
after which the smoke-ticket test can run.
