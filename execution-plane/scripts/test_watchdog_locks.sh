#!/usr/bin/env bash
# Phase 5 T1 verification: seed fresh/stale runs + locked issue, run dry-run
# + real watchdog, assert liveness semantics, cleanup. Self-contained.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PSQL="docker exec paperclip_postgres psql -U paperclip -d paperclip -v ON_ERROR_STOP=1 -tAq"

COMPANY=$($PSQL -c "SELECT id FROM companies LIMIT 1;")
if [ -z "$COMPANY" ]; then
    COMPANY=$($PSQL -c "INSERT INTO companies (name) VALUES ('wd-test') RETURNING id;" | head -n1)
fi
echo "company=$COMPANY"

FRESH=$(uuidgen)
STALE=$(uuidgen)
ISSUE=$(uuidgen)
AGENT=$($PSQL -c "INSERT INTO agents (company_id, name) VALUES ('$COMPANY', 'wd-test-agent') RETURNING id;" | head -n1)

# Run started 90 min ago but ACTIVITY 2 min ago -> FRESH, must survive (R10)
$PSQL -c "INSERT INTO heartbeat_runs (id, company_id, agent_id, status, started_at, updated_at, last_useful_action_at)
          VALUES ('$FRESH', '$COMPANY', '$AGENT', 'running', now() - interval '90 minutes', now() - interval '2 minutes', now() - interval '2 minutes');"
# Run started 90 min ago, activity 70 min ago -> STALE, must be purged
$PSQL -c "INSERT INTO heartbeat_runs (id, company_id, agent_id, status, started_at, updated_at, last_useful_action_at)
          VALUES ('$STALE', '$COMPANY', '$AGENT', 'running', now() - interval '90 minutes', now() - interval '70 minutes', now() - interval '70 minutes');"
# Issue locked by the STALE run
$PSQL -c "INSERT INTO issues (id, company_id, title, status, created_at, updated_at, checkout_run_id)
          VALUES ('$ISSUE', '$COMPANY', 'wd test issue', 'in_progress', now(), now(), '$STALE');"
echo "seeded fresh=$FRESH stale=$STALE issue=$ISSUE"

echo "=== DRY RUN ==="
bash execution-plane/scripts/watchdog-locks.sh --dry-run

echo "=== REAL RUN ==="
bash execution-plane/scripts/watchdog-locks.sh

echo "=== VERIFY: fresh run survives (status still running, no finish) ==="
$PSQL -c "SELECT id, status, finished_at FROM heartbeat_runs WHERE id = '$FRESH';"

echo "=== VERIFY: stale run failed with watchdog error ==="
$PSQL -c "SELECT id, status, error FROM heartbeat_runs WHERE id = '$STALE';"

echo "=== VERIFY: issue lock released (checkout_run_id NULL) ==="
$PSQL -c "SELECT id, checkout_run_id FROM issues WHERE id = '$ISSUE';"

echo "=== VERIFY: idempotent second run (exactly once) ==="
bash execution-plane/scripts/watchdog-locks.sh
LEFT=$($PSQL -c "SELECT count(*) FROM issues WHERE id = '$ISSUE' AND checkout_run_id IS NOT NULL;")
echo "locks still held after second run: $LEFT (expect 0)"

echo "=== VERIFY: watchdog log has entries ==="
tail -5 storage/paperclip_data/watchdog.log

echo "=== CLEANUP ==="
$PSQL -c "DELETE FROM issues WHERE id = '$ISSUE';"
$PSQL -c "DELETE FROM heartbeat_runs WHERE id IN ('$FRESH', '$STALE');"
$PSQL -c "DELETE FROM agents WHERE id = '$AGENT';"
echo TESTBLOCK_DONE
