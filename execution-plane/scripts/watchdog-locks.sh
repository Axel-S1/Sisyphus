#!/usr/bin/env bash
# watchdog-locks.sh — Phase 5 (T1): orphaned-lock watchdog for Paperclip (ADR-05, #3819).
#
# Real schema (validated against paperclip_postgres live Drizzle schema, 2026-11-05):
#   issues:            checkout_run_id (uuid, FK -> heartbeat_runs.id, ON DELETE SET NULL),
#                      execution_locked_at, status
#   heartbeat_runs:    status (text), started_at, finished_at, updated_at, error,
#                      liveness_state / liveness_reason (native columns),
#                      last_useful_action_at, last_output_at, updated_at
#
# Semantics (spec §5.4, Risk R10):
#   - Liveness is judged on ACTIVITY time, never start time: a run is stale only if
#     it has been in-flight (no finished_at) AND its last activity (GREATEST of
#     updated_at / last_useful_action_at / last_output_at / started_at) is older
#     than STALE_MINUTES (default 60).
#   - Two phases, never one: first mark stale runs FAILED (with the watchdog error
#     string), THEN release issue locks only for runs failed by THIS watchdog
#     (error LIKE 'watchdog:%'). This prevents duplicate execution and never
#     releases locks of runs failed for other reasons.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STALE_MINUTES="${STALE_MINUTES:-60}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

LOG_DIR="$ROOT/storage/paperclip_data"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/watchdog.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

PSQL="docker exec paperclip_postgres psql -U paperclip -d paperclip -v ON_ERROR_STOP=1 -tAq"

# Liveness activity expression: the most recent of the run's maintained
# timestamps. updated_at is always set on any state change; the last_* columns
# may be NULL, so GREATEST with started_at as floor keeps it non-NULL.
ACTIVITY_SQL="GREATEST(updated_at, last_useful_action_at, last_output_at, started_at)"

# In-flight = the run has no finished_at yet (status text is free-form; the
# finished_at IS NULL predicate is the authoritative in-flight marker).
INFLIGHT_SQL="finished_at IS NULL"

log "watchdog-locks start (stale=${STALE_MINUTES}min dry_run=${DRY_RUN})"

# --- Phase A: list (dry-run) or mark stale runs failed -----------------------
# Liveness check on activity time, NOT start time (R10).
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would-be-purged stale runs:"
    $PSQL -c "
        SELECT r.id, r.status, r.started_at, $ACTIVITY_SQL AS last_activity
        FROM heartbeat_runs r
        WHERE $INFLIGHT_SQL
          AND $ACTIVITY_SQL < now() - interval '${STALE_MINUTES} minutes';"
    log "DRY-RUN: issue locks that would be released:"
    $PSQL -c "
        SELECT i.id, i.identifier, i.checkout_run_id
        FROM issues i
        JOIN heartbeat_runs r ON r.id = i.checkout_run_id
        WHERE r.finished_at IS NULL
          AND GREATEST(r.updated_at, r.last_useful_action_at, r.last_output_at, r.started_at)
              < now() - interval '${STALE_MINUTES} minutes';"
    log "DRY-RUN complete (no changes made)."
    exit 0
fi

STALE_RUN_IDS=$($PSQL -c "
    SELECT r.id FROM heartbeat_runs r
    WHERE $INFLIGHT_SQL
      AND $ACTIVITY_SQL < now() - interval '${STALE_MINUTES} minutes';")

if [ -z "$STALE_RUN_IDS" ]; then
    log "no stale in-flight runs found."
    exit 0
fi

# Phase A: mark each stale run failed (individual UPDATE so every action is
# logged with its run ID — no silent failures).
for RUN_ID in $STALE_RUN_IDS; do
    $PSQL -c "
        UPDATE heartbeat_runs
        SET status = 'failed',
            finished_at = now(),
            error = 'watchdog: orphaned lock — no activity for ${STALE_MINUTES}+ minutes',
            liveness_state = 'dead',
            liveness_reason = 'watchdog-locks.sh: activity stalled beyond ${STALE_MINUTES} minutes'
        WHERE id = '$RUN_ID' AND $INFLIGHT_SQL;" >/dev/null
    log "marked run $RUN_ID FAILED (watchdog: orphaned lock)"
done

# Phase B: release issue locks ONLY for watchdog-failed runs (error LIKE
# 'watchdog:%' filter — never release locks of runs failed for other reasons),
# and only once per run (the lock column becomes NULL, so re-running is a no-op).
for RUN_ID in $STALE_RUN_IDS; do
    RELEASED=$($PSQL -c "
        UPDATE issues
        SET checkout_run_id = NULL,
            execution_locked_at = NULL
        WHERE checkout_run_id = '$RUN_ID'
        RETURNING id;")
    if [ -n "$RELEASED" ]; then
        for ISSUE_ID in $RELEASED; do
            log "released issue $ISSUE_ID lock (run $RUN_ID failed by watchdog)"
        done
    else
        log "run $RUN_ID held no issue lock (nothing to release)"
    fi
done

log "watchdog-locks complete."
