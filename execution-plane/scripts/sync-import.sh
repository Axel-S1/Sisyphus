#!/usr/bin/env bash
# sync-import.sh — Restore machine state from the private sisyphus-state repo (ADR-08).
#
# What it does:
#   1. Locates the private state repo, verifies checksum of the sanitized dump.
#   2. REFUSES to run if the Paperclip control-plane container is up (import
#      would drop/recreate the schema — a running Paperclip would corrupt or
#      lose in-flight state).
#   3. Re-verifies sanitization (no secret-table rows) as defense against a
#      tampered repo before touching the database.
#   4. With explicit confirmation (or --yes), drops the `public` schema and
#      restores paperclip-backup.sql into the local PostgreSQL container.
#   5. Warns about dirty git state, missing storage/ symlinks, and reminds
#      about excluded secret tables (provider/agent keys need re-entry).
#
# The `account` table IS in the dump — user logins survive the import.
#
# Usage: ./execution-plane/scripts/sync-import.sh [--yes]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

msg()  { printf '\033[1;34m[sync-import]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[sync-import]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sync-import] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[sync-import] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

# ── Locate the private state repo (same discovery as sync-export.sh) ───────
locate_state_dir() {
  local cand="${SISYPHUS_STATE_DIR:-$HOME/sisyphus-state}"
  cand="${cand/#\~/$HOME}"
  if [[ -d "$cand/.git" ]]; then echo "$cand"; return 0; fi
  shopt -s nullglob
  local link
  for link in "$REPO_ROOT"/storage/hermes_data/agent_*/memories \
              "$REPO_ROOT"/storage/goose_data/agent_*/config; do
    if [[ -L "$link" ]]; then
      local target dir; target="$(readlink -f "$link")"; dir="$target"
      while [[ "$dir" != "/" ]]; do
        [[ -d "$dir/.git" ]] && { echo "$dir"; return 0; }
        dir="$(dirname "$dir")"
      done
    fi
  done
  shopt -u nullglob
  return 1
}

STATE_DIR="$(locate_state_dir)" || die "private state repo not found. Run setup-sync.sh first (or set SISYPHUS_STATE_DIR)."
ok "state repo: $STATE_DIR"

EXPORTS="$STATE_DIR/paperclip_exports"
DUMP="$EXPORTS/paperclip-backup.sql"
SHA="$DUMP.sha256"

# ── 0. Git hygiene ─────────────────────────────────────────────────────────
if [[ -n "$(git -C "$STATE_DIR" status --porcelain 2>/dev/null)" ]]; then
  warn "private repo has uncommitted changes — import proceeds, but export"
  warn "  BEFORE leaving this machine or your local edits may be overwritten."
fi
if git -C "$STATE_DIR" fetch -q origin 2>/dev/null \
   && [[ "$(git -C "$STATE_DIR" rev-list --count HEAD..@{upstream} 2>/dev/null || echo 0)" -gt 0 ]]; then
  warn "state repo is BEHIND origin (non-fast-forward situation on next push)."
  warn "  Run: git -C \"$STATE_DIR\" pull --rebase  — then re-run sync-import.sh."
fi

# ── 1. Checksum verification (required) ────────────────────────────────────
[[ -f "$DUMP" ]] || die "no dump found at $DUMP — run sync-export.sh on the other machine first."
[[ -f "$SHA"  ]] || die "checksum file missing ($SHA) — refusing to restore an unverifiable dump."
( cd "$EXPORTS" && sha256sum --check --status "$(basename "$SHA")" ) \
  || die "checksum MISMATCH for $(basename "$DUMP") — dump corrupted or tampered. Aborting."
ok "checksum verified: $(awk '{print $1}' "$SHA")"

# ── 2. Sanitization re-verification (defense against tampered repo) ────────
leak="$(grep -E '^COPY (public\.)?(company_secrets|company_secret_versions|agent_api_keys|ai_connection_pools|user_secret_definitions) ' "$DUMP" || true)"
[[ -z "$leak" ]] || die "dump contains plaintext secret-table rows — tampered or outdated. Aborting (R8)."
ok "sanitization verified (no secret-table rows)"

# ── 3. Container state gates ───────────────────────────────────────────────
RUNNING_PAPERCLIP="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x 'paperclip_control_plane' || true)"
[[ -z "$RUNNING_PAPERCLIP" ]] || die "Paperclip container is RUNNING — stop it first: ./stop.sh (or 'docker compose stop paperclip'). Restoring schema under a live control plane would corrupt in-flight state."
POSTGRES_UP="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x 'paperclip_postgres' || true)"
[[ -n "$POSTGRES_UP" ]] || die "PostgreSQL container is not running — start it: docker compose up -d postgres"
ok "container gates passed (paperclip down, postgres up)"

# ── 4. Symlink sanity (Tier 1 — text state) ────────────────────────────────
MISSING_LINKS=0
shopt -s nullglob
for agent_dir in "$REPO_ROOT"/storage/hermes_data/agent_*; do
  [[ -L "$agent_dir/memories" ]] || { warn "missing symlink: $agent_dir/memories (run setup-sync.sh)"; MISSING_LINKS=1; }
done
for agent_dir in "$REPO_ROOT"/storage/goose_data/agent_*; do
  [[ -L "$agent_dir/config" ]] || { warn "missing symlink: $agent_dir/config (run setup-sync.sh)"; MISSING_LINKS=1; }
done
shopt -u nullglob
[[ "$MISSING_LINKS" == 0 ]] || warn "text-state links incomplete — memories/config may not follow the synced repo."

# ── 5. Confirmation (DESTRUCTIVE: drops public schema) ─────────────────────
dump_date="$(head -c 4096 "$DUMP" | grep -m1 -oE -e '-- Dumped from database version [^ ]*' || true)"
echo
echo "  About to DESTROY and restore the local Paperclip database:"
echo "    DROP SCHEMA public CASCADE;  →  restore paperclip-backup.sql"
echo "    dump: $DUMP ($(du -h "$DUMP" | cut -f1), $dump_date)"
echo
if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "  Type 'restore' to continue, anything else aborts: " answer
  [[ "$answer" == "restore" ]] || { warn "aborted by operator — nothing was changed."; exit 1; }
fi

# ── 6. Restore ─────────────────────────────────────────────────────────────
msg "dropping public schema..."
docker exec -i paperclip_postgres psql -U paperclip -d paperclip -v ON_ERROR_STOP=1 -q \
  -c 'DROP SCHEMA public CASCADE;' -c 'CREATE SCHEMA public;' \
  -c 'DROP SCHEMA IF EXISTS drizzle CASCADE;' \
  || die "failed to drop schema — database untouched by restore step."

msg "restoring dump (this can take a moment)..."
docker exec -i paperclip_postgres psql -U paperclip -d paperclip -v ON_ERROR_STOP=1 -q \
  < "$DUMP" || die "restore FAILED mid-way (partial state). Re-run with --yes after fixing the cause; the dump remains intact."

ok "restore complete"

# ── 7. Post-restore verification + reminders ───────────────────────────────
USERS="$(docker exec paperclip_postgres psql -U paperclip -d paperclip -tAc 'SELECT count(*) FROM "user";' 2>/dev/null || echo '?')"
COMPANIES="$(docker exec paperclip_postgres psql -U paperclip -d paperclip -tAc 'SELECT count(*) FROM companies;' 2>/dev/null || echo '?')"
ok "post-restore counts: users=$USERS companies=$COMPANIES"

cat <<BANNER

════════════════════════════════════════════════════════════
  Import complete (ADR-08)
  ⚠ Excluded secret tables were NOT restored — re-enter in the
    Paperclip UI (http://localhost:3000) or re-seed:
      company_secrets / agent_api_keys / ai_connection_pools
  ⚠ Logins survived (hashed 'account' table restored).
  Next:  ./start.sh   (bring the stack back up)
════════════════════════════════════════════════════════════
BANNER
