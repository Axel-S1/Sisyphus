# Phase 5/6 — Reliability: Lock Watchdog (#3819) + Network Backoff (#6596)

> Status: **Plan** (not yet executed — re-opened by the 2026-11-06
> Refactoring & Security Sprint; an earlier aborted run left
> `watchdog-locks.sh` in place, but **none of its acceptance criteria have
> been verified**). Spec reference: ADR-05 (#3819, #6596), §5.4 (watchdog
> SQL + liveness semantics), Risks R3/R6/R10. Depends on: Phase 3 (running
> Paperclip + PostgreSQL/Drizzle).
>
> ⚠️ **Task 2 re-planning note:** the aborted run's `backoff_proxy.py` was
> **deleted** as structural debt — it was never referenced by any adapter
> config, compose file, or startup script, so the #6596 mitigation existed
> only as an unreachable standalone script. Re-implement per this doc's
> implementation note (adapter-config-level retry if the real schema
> supports it) **with wiring**, or record the deferral explicitly.

## Objective

Eliminate the two "silent failure" modes of the control loop:

1. **#3819 — Orphaned locks:** a run crashes silently, its checkout stays
   claimed, progress stalls with no visible error.
2. **#6596 — Offline run storm:** during a disconnection Paperclip creates a
   massive number of runs, saturating adapter logs on reconnect.

## Verified environment facts (from Phases 1–3)

- The **real Paperclip Drizzle schema** was applied at boot (Phase 3).
  Table names relevant here: **`issues`** (the spec's "tickets"),
  **`heartbeat_runs`** / **`native_run_results`** / **`routine_runs`**
  (the spec's "runs"), plus `goals` and `companies`. The spec §5.4 SQL
  (`tickets`, `runs`, `checkout_run_id`) is **illustrative** — the exact
  column names must be read from the live schema before writing the SQL
  (e.g. `SELECT column_name FROM information_schema.columns WHERE
  table_name='issues'`).
- There are **no systemd units** (ADR-07): the watchdog timer must be a cron
  entry or a launcher-side periodic hook, *not* a systemd timer.
- The container is `paperclip_control_plane`; PostgreSQL runs as
  `paperclip_postgres` and is reachable via
  `docker exec paperclip_postgres psql -U paperclip -d paperclip …`.
- Paperclip is in `authenticated` mode with `bootstrap_pending`; some
  API-side probes may require the one-time human onboarding first.

## Task 1 — Orphaned-lock watchdog (with v2.1 liveness semantics)

### Semantics (must be respected exactly — Risk R10)

A 60-minute-old lock is **not** automatically orphaned — legitimately long
runs exist. The purge must therefore:

- **(a)** check run *liveness* (no activity update for > 60 min, not merely an
  old start time), and
- **(b)** mark the stale run **`failed`** (not silently reopen the issue as
  `ready` first) — otherwise two agents can end up working the same issue
  (duplicate-execution risk). Only runs already marked `failed` by the
  watchdog release their issue's lock.

### Implementation

`execution-plane/scripts/watchdog-locks.sh` — scheduled every 10 minutes
(cron entry or launcher periodic hook). Illustrative SQL from spec §5.4 —
**validate table/column names against the live Drizzle schema before
deploying**:

```sql
-- Mark stale runs failed (liveness check on activity time, not start time)
UPDATE runs
SET status = 'failed', finished_at = now(),
    error = 'watchdog: orphaned lock — no activity for 60+ minutes'
WHERE finished_at IS NULL
  AND started_at < now() - interval '60 minutes'
  AND last_activity_at < now() - interval '60 minutes';

-- Only then release issues whose run failed under the watchdog
UPDATE tickets
SET checkout_run_id = NULL, status = 'ready'
WHERE checkout_run_id IS NOT NULL
  AND checkout_run_id IN (
    SELECT id FROM runs WHERE status = 'failed' AND error LIKE 'watchdog:%'
  );
```

Alternative accepted implementation: a **priority API endpoint** in Paperclip
doing the same purge (the spec allows either). Choose one; script + scheduler
is the default.

Suggested runner: the shell script invokes
`docker exec paperclip_postgres psql -U paperclip -d paperclip -c "<sql>"`,
logs each purge to `storage/paperclip_data/watchdog.log`, and takes a
`--dry-run` flag that only *lists* would-be-purged runs (use it for the
acceptance test).

### Deliverables

- `execution-plane/scripts/watchdog-locks.sh` (+ `--dry-run`)
- Scheduler wiring: cron entry (10 min) or launcher periodic hook —
  **not** systemd (ADR-07).

## Task 2 — Exponential backoff on adapter retries (#6596)

In Paperclip's adapter layer (both Hermes and Goose clients):

- On request failure, retry with **exponential backoff** (base 2 s, factor 2,
  jitter; max retries configurable, default 6).
- On low-level network errors — `ENOTFOUND`, `ECONNREFUSED` — **suspend
  analytical reviews** (and any fan-out run creation) until connectivity is
  restored; do not create new runs while offline.
- Reconnect must be idempotent: no duplicate run creation on retry (use
  idempotency keys / check-before-create against the issue state).
- Log storm metrics: rate of run creations per minute; alarm/back off if a
  threshold is exceeded during outage.

Implementation note: Paperclip's adapter code is external (upstream image);
implement as a wrapping HTTP client/proxy in front of the adapter targets, or
as a config-level retry policy if the real adapter schema exposes one
(`timeoutSec`, `eventReconnectMs` are known fields from Phase 3 — check for a
retry/backoff field in the live docs before hand-rolling).

## Verification tests

- `--dry-run` against a **fresh** run (started 61 min ago but activity < 2 min
  ago) → **not** purged (liveness check works; R10 test).
- A test run with activity > 60 min → marked `failed` with the watchdog error
  string; its issue's lock cleared **exactly once** (no duplicate execution).
- A legitimately long-but-active run is never purged.
- With the container disconnected, no run storm: run-creation rate stays ~0
  during the outage; retries back off exponentially.
- No silent failure: every watchdog action is logged with run IDs.

## Acceptance criteria

- [ ] Watchdog script + `--dry-run` in place; scheduler wired (non-systemd).
- [ ] Liveness semantics verified (fresh-but-old-start run survives;
      stale-activity run purged exactly once).
- [ ] Backoff + offline suspension verified with a simulated disconnect.
- [ ] Real schema column names validated and recorded in the script comments.
- [ ] No silent failure: every action logged.

## Common pitfalls

- Purging on start-time alone → kills long legitimate runs (R10).
- Releasing the issue lock in the same UPDATE that marks the run failed,
  without the watchdog-error filter → releases locks of *all* failed runs.
- Backoff without jitter → thundering herd on reconnect.
- Hard-coding the illustrative table names without checking the live schema.
- Wiring the scheduler into systemd — deprecated by ADR-07.

## Outputs for next phase

Phase 6 runs the full Go/No-Go checklist; the watchdog and backoff must be
active during the E2E.
