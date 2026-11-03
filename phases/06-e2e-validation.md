# Phase 6/6 — E2E Validation & Go/No-Go (MVP exit)

> Spec reference: §4 Phase 1 E2E, §8 (Go/No-Go checklist), Risks R2–R10.
> Depends on: Phases 1–5 all complete.

## Objective

Run the full validation suite that gates the MVP. **The MVP is declared
complete only if every checkbox below passes.** Do not re-implement anything
here except trivial test scaffolding; this phase is for verification and for
fixing defects discovered by it.

## Task 1 — The end-to-end scenario (spec §4, Phase 1 E2E)

Execute exactly this sequence, keeping evidence (logs, screenshots, curl
outputs) for the report:

1. `docker compose up -d` → Paperclip healthy.
2. Create a task via Paperclip UI/API:
   *"Generate a Python math utility module and its unit tests."*
3. CEO agent (`run.sh ceo` or its systemd unit) → writes a technical
   specification ticket into `execution-plane/workspace`.
4. Dev agent (`run.sh dev`, goose profile) → reads the spec, writes the
   Python module, runs `pytest` **on the host under
   `GOOSE_MODE=smart_approve` with human confirmation of the test run**.
   ⚠️ Ephemeral sandboxing is **not** part of the MVP (spec Phase 3) — do
   not claim sandboxed execution anywhere in the report.
5. Dev agent's confirmation is reported back to Paperclip; the ticket
   closes.

Exit conditions: no corrupted sessions, no residual orphaned locks, no
ghost runs.

## Task 2 — Go/No-Go checklist (spec §8, verbatim)

Check each item; a failure = No-Go until fixed:

- [ ] `host.docker.internal:8642` responds from inside the Paperclip
      container (curl + `API_SERVER_KEY`).
- [ ] `goose serve`'s `/acp` endpoint answers the `initialize` handshake
      (JSON-RPC 2.0) from **inside** the container — confirms
      `GOOSE_SERVER__HOST=0.0.0.0` and correct port. A timeout here means a
      localhost bind or the stdio command (`goose acp`) is in use.
- [ ] Two Goose profiles launched on **distinct ports** (ADR-06) → zero
      cross-writes to configs (collision test).
- [ ] Two Goose profiles launched **concurrently** → zero cross-writes to
      configs.
- [ ] `PRAGMA journal_mode` returns `delete` for every database on a Docker
      mount.
- [ ] `execute_code` runs with an empty `PYTHONPATH` (test:
      `import hermes_cli` must fail from the sandbox).
- [ ] `persistSession: false` verified in the adapter configuration.
- [ ] The watchdog purges a test lock older than 60 minutes (see Phase 5
      dry-run/procedure).
- [ ] Full E2E CEO → Dev → `pytest` → Paperclip confirmation, with no ghost
      runs.
- [ ] `tool_permissions.json` blocks access to `.env` and `secrets/`
      (negative test).

## Task 3 — Remediation loop

For every failed checkbox: diagnose → fix in the responsible phase's
artifacts → re-run that phase's acceptance criteria **and** this checklist.
Log each failure/fix pair in the final report.

## Deliverables

- `docs/mvp-validation-report.md` containing:
  - E2E transcript (step-by-step, with evidence).
  - Go/No-Go table: item → pass/fail → evidence link.
  - All fixes applied (phase → defect → fix).
  - Explicit out-of-scope note: sandboxing, RAG, local inference, and
    `GOOSE_MODE=auto` are NOT part of the MVP (spec Phases 2–5).
  - Known deviations from the spec (e.g. adapted env-var names per ADR-06
    schema caution) with justification.

## MVP completion statement template

```markdown
MVP (spec Phase 1) complete on <date>.
Go/No-Go: 10/10 PASS. E2E: PASS (evidence: <links>).
Deviations: <list or "none">.
Next milestone: spec Phase 2 (profile compartmentalization, collision
audits, versioned tool_permissions, full collision suite).
```

## Common pitfalls

- Declaring MVP complete with one checkbox "probably fine" — no partial
  passes; a red checkbox is a No-Go.
- Running the E2E with `GOOSE_MODE=auto` for convenience — that invalidates
  the run (Risk R7).
- Forgetting the from-inside-the-container tests — host-side success
  proves nothing about the Docker↔host boundary (the core of the whole
  architecture).
- Treating sandboxed execution as done — it does not exist until spec
  Phase 3.
