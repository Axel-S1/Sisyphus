# Phase 6/6 — E2E Validation & Go/No-Go (MVP exit)

> Status: **Plan** (not yet executed). Spec reference: §4 Phase 1 E2E, §8
> (Go/No-Go checklist), Risks R2–R10. Depends on: Phases 1–5 complete.

## Objective

Run the full validation suite that gates the MVP. **The MVP is declared
complete only if every checkbox in the checklist below passes.** Do not
re-implement anything here except trivial test scaffolding; this phase is for
verification and for fixing defects discovered by it.

## Task 1 — The end-to-end scenario

Execute exactly this sequence, keeping evidence (logs, transcripts, curl
outputs) for the report:

1. `./start.sh` → launcher up, `docker compose up -d` → Paperclip healthy.
2. **Prerequisite:** the Paperclip one-time onboarding (company + owner
   account at <http://localhost:3000>) is completed — the smoke-ticket test
   requires it (Phase 3 deferral).
3. Create a task via Paperclip UI/API: *"Generate a Python math utility
   module and its unit tests."*
4. CEO agent (`run.sh ceo hermes` or launcher-launched) → writes a technical
   specification into `execution-plane/workspace`.
5. Dev agent (`run.sh dev goose`, `GOOSE_MODE=smart_approve`) → reads the
   spec, writes the Python module, runs `pytest` **on the host with human
   confirmation** of the test run.
   ⚠️ Ephemeral sandboxing is **not** part of the MVP — do not claim
   sandboxed execution anywhere in the report.
6. Dev's confirmation is reported back to Paperclip; the ticket closes.

Exit conditions: no corrupted sessions, no residual orphaned locks, no ghost
runs.

## Task 2 — Go/No-Go checklist

Reproduced from spec §8 (verified facts marked):

- [x] Goose `/acp` answers the `initialize` handshake (JSON-RPC 2.0) from
      **inside** the container with `X-Secret-Key` — confirmed Phase 3
      (`goose serve --host 0.0.0.0 --port 3284`; a timeout here would mean a
      localhost bind or the stdio command `goose acp` in use).
- [x] **401 without** the secret (negative auth test) — confirmed Phase 3.
- [ ] Hermes endpoint answers from inside the container (with auth provider
      credentials) — setup lands with agent wiring.
- [x] Two Goose profiles on **distinct ports** (ADR-06) launched
      **concurrently** → zero cross-writes to configs — confirmed Phase 2.
- [ ] `execute_code` runs with an empty `PYTHONPATH`; `import hermes_cli`
      fails from within it (Phase 4).
- [ ] Fresh-session-per-run contract verified in the live adapter config
      (`sessionKeyStrategy: 'run'`; the historical `persistSession: false`
      field does not exist in real Paperclip).
- [ ] The watchdog purges a stale-activity test lock (Phase 5 procedure).
- [ ] Full E2E CEO → Dev → `pytest` → Paperclip confirmation, with no ghost
      runs.
- [ ] Tool-permission policy blocks access to `.env` and `secrets/`
      (negative test — Phase 4).
- [ ] A destructive-action request surfaces a human-approval prompt
      (`smart_approve`), not silent execution.

## Task 3 — Remediation loop

For every failed checkbox: diagnose → fix in the responsible phase's
artifacts → re-run that phase's acceptance criteria **and** this checklist.
Log each failure/fix pair in the final report.

## Deliverables

- `docs/mvp-validation-report.md` containing:
  - E2E transcript (step-by-step, with evidence).
  - Go/No-Go table: item → pass/fail → evidence link.
  - All fixes applied during the remediation loop.
  - Explicit out-of-scope note: sandboxing, RAG, local inference, and
    `GOOSE_MODE=auto` are NOT part of the MVP.
  - Known deviations from the original spec plans (see the implementation
    records in phases 01–03 for the full list).

## MVP completion statement template

```markdown
MVP (spec Phase 1) complete on <date>.
Go/No-Go: 11/11 PASS. Evidence: docs/mvp-validation-report.md.
Deviations: see phase docs 01–03 (hermes serve, goose serve flags,
X-Secret-Key, real Paperclip contract, sessionKeyStrategy).
Next milestone: spec Phase 2 (profile compartmentalization audits,
versioned permission policy, full collision suite).
```
