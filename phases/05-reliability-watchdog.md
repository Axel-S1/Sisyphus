# Phase 5/6 — Reliability: Lock Watchdog (#3819) + Network Backoff (#6596)

> Spec reference: ADR-05 (#3819, #6596), §5.4 (watchdog SQL + v2.1 liveness
> semantics), Risk R3/R6/R10.
> Depends on: Phase 3 (running Paperclip + PostgreSQL/Drizzle with the
> `runs`/`tickets` schema).

## Objective

Eliminate the two "silent failure" modes of the control loop:

1. **#3819 — Orphaned locks:** a run crashes silently, its `checkoutRunId`
   stays on the ticket, progress stalls with no visible error.
2. **#6596 — Offline run storm:** during a disconnection Paperclip creates a
   massive number of runs, saturating adapter logs on reconnect.

## Task 1 — Orphaned-lock watchdog (with v2.1 liveness semantics)

### Semantics (must be respected exactly — Risk R10)

A 60-minute-old lock is **not** automatically orphaned — legitimately long
runs exist. The purge must therefore:

- **(a)** check run *liveness* (no `last_activity_at` update for > 60 min,
  not merely an old start time), and
- **(b)** mark the stale run **`failed`** (not silently reopen the ticket as
  `ready` first) — otherwise two agents can end up working the same ticket
  (duplicate-execution risk). Only runs already marked `failed` by the
  watchdog release their ticket's lock.

### Implementation

`execution-plane/scripts/watchdog-locks.sh` — scheduled every 10 minutes
(cron/systemd timer `watchdog-locks.timer`). Illustrative SQL from spec
§5.4 — **validate table/column names against the real Drizzle schema
before deploying**:

```sql
-- Mark stale runs failed (liveness check on last_activity_at, not start time)
UPDATE runs
SET status = 'failed', finished_at = now(),
    error = 'watchdog: orphaned lock — no activity for 60+ minutes'
WHERE finished_at IS NULL
  AND started_at < now() - interval '60 minutes'
  AND last_activity_at < now() - interval '60 minutes';

-- Only then release tickets whose run failed under the watchdog
UPDATE tickets
SET checkout_run_id = NULL, status = 'ready'
WHERE checkout_run_id IS NOT NULL
  AND checkout_run_id IN (
    SELECT id FROM runs WHERE status = 'failed' AND error LIKE 'watchdog:%'
  );
```

Alternative accepted implementation: a **priority API endpoint** in
Paperclip doing the same purge (spec allows either). Choose one; script +
timer is the default.

Suggested runner: the shell script invokes `docker exec paperclip_postgres_1
psql -U paperclip -d paperclip -c "<sql>"` (or `psql` directly with
connection env), logs each purge to
`storage/paperclip_data/watchdog.log`, and takes a `--dry-run` flag that
only *lists* would-be-purged runs (use it for the acceptance test).

### Deliverables

- `execution-plane/scripts/watchdog-locks.sh` (+ `--dry-run`)
- `execution-plane/scripts/systemd/watchdog-locks.service` +
  `watchdog-locks.timer` (every 10 min, `OnUnitActiveSec=10min`)

## Task 2 — Exponential backoff on adapter retries (#6596)

In Paperclip's adapter layer (both Hermes and Goose clients):

- On request failure, retry with **exponential backoff** (e.g. base 2s,
  factor 2, cap 5 min, jitter; max retries configurable, default 6).
- On low-level network errors — `ENOTFOUND`, `ECONNREFUSED` — **suspend
  analytical reviews** (and any fan-out run creation) until connectivity
  is restored; do not create new runs while offline.
- Reconnect must be idempotent: no duplicate run creation on retry (use
  run-creation idempotency keys or check-before-create against the ticket
  state).
- Log storm metrics: rate of run creations per minute; alarm/back off if a
  threshold is exceeded during outage.

Implementation note: if Paperclip's adapter code is external (npm package),
implement a wrapping HTTP client (axios/fetch interceptor) in the
control-plane code and wire it into both adapters' transports.

## Acceptance criteria

- [ ] `--dry-run` against a **fresh** run (started 61 min ago but with
      `last_activity_at` < 2 min ago) → **not** purged (liveness check works;
      R10 test).
- [ ] A test run with `last_activity_at` > 60 min → marked `failed` with the
      watchdog error string; its ticket's `checkout_run_id` cleared and
      ticket back to `ready` — **exactly once** (no duplicate execution).
- [ ] A legitimately long-but-active run is never purged.
- [ ] Watchdog timer fires every 10 min (`systemctl list-timers`).
- [ ] With the container disconnected, no run storm: run-creation rate
      stays ~0 during outage; on reconnect, retries use exponential backoff
      and no duplicate runs are created.
- [ ] No silent failure: every watchdog action is logged with run IDs.

## Common pitfalls

- Purging on `started_at` alone → kills long legitimate runs (R10).
- Releasing the ticket in the same UPDATE that marks the run failed, without
  the `watchdog:%` error filter → releases locks of *all* failed runs,
  including ones a live agent may have re-claimed.
- Backoff without jitter → thundering herd on reconnect.
- Hardcoding the illustrative table names without checking the Drizzle
  schema.

## Outputs for next phase

Phase 6 runs the full Go/No-Go checklist; the watchdog and backoff must be
active during the E2E.
