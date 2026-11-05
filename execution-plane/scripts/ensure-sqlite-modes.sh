#!/usr/bin/env bash
# ensure-sqlite-modes.sh — Enforce SQLite journal_mode=delete for every SQLite DB
# under storage/ (goose sessions.db, hermes state.db, any future DB).
# (ADR-04; prevents the WAL-on-virtiofs DeletedWalGenerationError failure mode.)
# Idempotent: safe to run repeatedly (also via run.sh before each daemon start).
set -euo pipefail

# Resolve repo root relative to this script (portable; no hard-coded paths).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STORAGE_DIR="$ROOT/storage"

echo "[INFO] Enforcing SQLite journal_mode=delete under $STORAGE_DIR"

if [ ! -d "$STORAGE_DIR" ]; then
    echo "[WARN] $STORAGE_DIR does not exist yet — nothing to enforce."
    exit 0
fi

changed=0
found=0
while IFS= read -r -d '' db; do
    found=$((found + 1))
    CURRENT_MODE="$(sqlite3 "$db" "PRAGMA journal_mode;")"
    if [ "$CURRENT_MODE" != "delete" ]; then
        echo "[INFO] $db: journal_mode $CURRENT_MODE -> delete"
        sqlite3 "$db" "PRAGMA journal_mode=delete;"
        changed=$((changed + 1))
    fi
done < <(find "$STORAGE_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

# Verify: every DB must now report journal_mode=delete.
fail=0
while IFS= read -r -d '' db; do
    mode="$(sqlite3 "$db" "PRAGMA journal_mode;")"
    if [ "$mode" != "delete" ]; then
        echo "[ERROR] $db still reports journal_mode=$mode"
        fail=1
    fi
done < <(find "$STORAGE_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

echo "[INFO] SQLite journal-mode enforcement complete: found=$found changed=$changed"
if [ "$fail" -ne 0 ]; then
    echo "[ERROR] One or more DBs failed verification."
    exit 1
fi
echo "[OK] All SQLite DBs under storage/ report journal_mode=delete."
