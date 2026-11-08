# Phase Documentation — Path to MVP

This directory contains the **execution plan to reach the MVP** of the
"Local-First Multi-Agent System" (Paperclip · Hermes · Goose).

Source of truth: [`../spec/architecture-spec.md`](../spec/architecture-spec.md)
(v2.4). The MVP is the spec's **Phase 1**,
decomposed here into **6 sequential sub-phases**, each sized for one autonomous
agent run.

---

## Execution order (strict)

| # | Phase doc | Scope | Status | Depends on |
|---|-----------|-------|--------|------------|
| 1 | [`01-monorepo-scaffolding.md`](01-monorepo-scaffolding.md) | Repo tree, `.gitignore`, `.env.example`, `ports.env.example` (ADR-06) | ✅ Done | — |
| 2 | [`02-execution-plane-daemons.md`](02-execution-plane-daemons.md) | `run.sh`/`run.ps1`, Hermes + Goose daemons, profiles, collision test | ✅ Done | 01 |
| 3 | [`03-control-plane-paperclip.md`](03-control-plane-paperclip.md) | Real Paperclip + PostgreSQL in Docker, `adapters.json`, Host Launcher (ADR-07), connectivity tests | ✅ Done | 01, 02 |
| 4 | [`04-security-mitigations.md`](04-security-mitigations.md) | `PYTHONPATH` patch (CVE-2026-9368), `GOOSE_MODE=smart_approve`, tool-permission policy | ⬜ **Pending** | 02 |
| 5 | [`05-reliability-watchdog.md`](05-reliability-watchdog.md) | Orphaned-lock watchdog (#3819, liveness semantics), exponential backoff (#6596) | ⬜ **Pending** | 03 |
| 6 | [`06-e2e-validation.md`](06-e2e-validation.md) | Go/No-Go checklist execution, full E2E CEO → Dev → pytest → Paperclip | ⬜ Pending | all |

**MVP is declared complete only when every checkbox in
[`06-e2e-validation.md`](06-e2e-validation.md) passes.** Explicitly out of MVP
scope (spec Phases 2–5 of the *spec's* plan): ephemeral sandboxing, Qdrant/RAG,
local Ollama, `GOOSE_MODE=auto`, issue-scoped persistent sessions.

Documents for phases 1–3 are **as-built records**: what was built, how it was
verified, and every deviation from the original sketch. Documents for phases
4–6 are **forward-looking plans** written against the verified environment
facts of phases 1–3.

## Instructions for the executing agent

1. **Read the phase doc end-to-end before writing any code.**
2. **Do exactly one phase per run.** Later phases assume earlier artifacts exist.
3. **Verify each acceptance criterion yourself** with the commands in the doc's
   verification section before declaring the phase done. Keep evidence
   (command output, log excerpts) in the phase doc's as-built notes.
4. **Never modify settled decisions.** The ADRs in the spec (§3) are final.
   If a phase doc conflicts with the spec, the spec wins — report the conflict
   instead of improvising.
5. **⚠️ Schema caution:** several names are *illustrative* (adapter env-var
   names, watchdog SQL table/column names, `tool_permissions.json` schema).
   Validate against the **actual installed component** and adapt, keeping the
   durable contract (URLs, secrets, policy intent) intact. Verified-facts
   notes at the top of each pending phase doc record what is already known.
6. **Secrets hygiene (R8):** never commit `.env`, `ports.env`,
   `storage/goose_data/**`, `storage/hermes_data/**` (all agent state —
   `state.db`, `auth.lock`, memories, locks — is ignored wholesale),
   `storage/paperclip_data/*` (except `.gitkeep`), or Postgres data dirs.
   If any appear in Git, stop and fix immediately.
7. **Never use stdio-only commands** (`goose acp`, `hermes acp`) for the
   network server — and never use `hermes gateway` (messaging gateway). The
   network daemons are `goose serve` and `hermes serve`. This single mistake
   is Risk R9 and produces a silently dead daemon.
8. **Non-loopback binds are mandatory** for cross-boundary traffic
   (`goose serve --host 0.0.0.0` etc.), together with auth headers and host
   firewall rules (`ufw allow in on docker0` on this reference host).
9. When a phase has multiple independent tasks, prefer parallel
   exploration, but never have two agents write the same file.
10. Finish your run with: a summary of what was built, acceptance-criteria
    results (pass/fail + evidence), and any deviations or open questions for
    the next phase.
