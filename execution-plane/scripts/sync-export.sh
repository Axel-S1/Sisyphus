#!/usr/bin/env bash
# sync-export.sh — Export machine state to the private sisyphus-state repo (ADR-08).
#
# What it does:
#   1. Locates the private state repo (see locate_state_dir below).
#   2. Runs a SANITIZED pg_dump of the Paperclip PostgreSQL database into
#      paperclip_exports/paperclip-backup.sql (+ .sha256 checksum).
#      Excluded (plaintext-secret tables, schema kept for FK integrity):
#        company_secrets, company_secret_versions, agent_api_keys,
#        ai_connection_pools, user_secret_definitions
#      The `account` table IS included (hashed passwords — logins survive).
#   3. Verifies the dump really is sanitized (no COPY for excluded tables) and
#      that no blocked files (*.db, *.sql.gz, backups/, secrets) are tracked
#      or staged in the private repo.
#   4. Commits everything, and pushes if a remote is configured (offline
#      tolerated — matches run.sh philosophy).
#
# Usage: ./execution-plane/scripts/sync-export.sh [--no-commit] [--push]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

msg()  { printf '\033[1;34m[sync-export]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[sync-export]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sync-export] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[sync-export] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

NO_COMMIT=0; WANT_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --no-commit) NO_COMMIT=1 ;;
    --push)      WANT_PUSH=1 ;;
    *) die "unknown flag: $arg (usage: sync-export.sh [--no-commit] [--push])" ;;
  esac
done

# ── Locate the private state repo ──────────────────────────────────────────
locate_state_dir() {
  # 1) explicit override  2) default path  3) discovered via storage/ symlinks
  local cand="${SISYPHUS_STATE_DIR:-$HOME/sisyphus-state}"
  cand="${cand/#\~/$HOME}"
  if [[ -d "$cand/.git" ]]; then echo "$cand"; return 0; fi
  shopt -s nullglob
  local link
  for link in "$REPO_ROOT"/storage/hermes_data/agent_*/memories \
              "$REPO_ROOT"/storage/goose_data/agent_*/config; do
    if [[ -L "$link" ]]; then
      local target dir
      target="$(readlink -f "$link")"
      dir="$target"
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

# ── 2. Sanitized pg_dump (Tier 2 of ADR-08) ────────────────────────────────
EXPORTS="$STATE_DIR/paperclip_exports"
mkdir -p "$EXPORTS"
DUMP="$EXPORTS/paperclip-backup.sql"

# Plaintext-secret tables: rows excluded, schema kept (--exclude-table-data)
# so foreign keys remain restorable. NOT excluded: account (hashed passwords).
EXCLUDES=(
  company_secrets
  company_secret_versions
  agent_api_keys
  ai_connection_pools
  user_secret_definitions
)
DUMP_DONE=0

if docker compose -f "$REPO_ROOT/docker-compose.yml" ps postgres >/dev/null 2>&1 \
   && [[ "$(docker compose -f "$REPO_ROOT/docker-compose.yml" ps -q postgres 2>/dev/null)" != "" ]]; then
  pgargs=(--username paperclip --dbname paperclip --no-owner --no-privileges)
  for t in "${EXCLUDES[@]}"; do pgargs+=("--exclude-table-data=public.$t"); done
  msg "running sanitized pg_dump (postgres service, compose)..."
  if docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T postgres pg_dump "${pgargs[@]}" > "$DUMP"; then
    DUMP_DONE=1
  else
    warn "pg_dump via compose failed — dump skipped; text state will still sync."
  fi
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'paperclip_postgres'; then
  pgargs=(--username paperclip --dbname paperclip --no-owner --no-privileges)
  for t in "${EXCLUDES[@]}"; do pgargs+=("--exclude-table-data=public.$t"); done
  msg "running sanitized pg_dump (docker exec paperclip_postgres)..."
  if docker exec paperclip_postgres pg_dump "${pgargs[@]}" > "$DUMP"; then
    DUMP_DONE=1
  else
    warn "pg_dump via docker exec failed — dump skipped; text state will still sync."
  fi
else
  warn "Paperclip PostgreSQL is not running — skipping SQL dump (text state still syncs)."
fi

if [[ "$DUMP_DONE" == 1 ]]; then
  # ── Sanitization proof: no COPY for any excluded table ──
  leak="$(grep -E '^COPY (public\.)?(company_secrets|company_secret_versions|agent_api_keys|ai_connection_pools|user_secret_definitions) ' "$DUMP" || true)"
  [[ -z "$leak" ]] || die "dump contains rows of a secret table — refusing to export. Investigate before proceeding."
  ok "dump is sanitized (no secret-table rows)"
  ( cd "$EXPORTS" && sha256sum "$(basename "$DUMP")" > "$(basename "$DUMP").sha256" )
  ok "checksum written: $DUMP.sha256"
  rm -f "$EXPORTS/paperclip-backup.sql.tmp" 2>/dev/null || true
fi

# ── 3. Blocked-file verification (ADR-08 hard exclusions) ──────────────────
BLOCKED_RE='(^|/)([^/]*\.db(-wal|-shm)?|[^/]*\.sqlite3?(-wal|-shm)?|[^/]*\.sql\.gz|auth\.lock|\.env|ports\.env|[^/]*\.pem|[^/]*\.key|id_rsa[^/]*|backups/[^/]*|paperclip_pgdata/[^/]*[^/]*)$'
# Any tracked file matching a blocked pattern is a pre-existing violation:
viol="$(git -C "$STATE_DIR" ls-files | grep -E "$BLOCKED_RE" || true)"
[[ -z "$viol" ]] || die "blocked files already TRACKED in private repo:\n$viol\nUntrack them (git rm --cached) before exporting."
# Anything about to be staged must not be git-ignored (belt & suspenders):
staged="$(git -C "$STATE_DIR" add -A -n 2>/dev/null | sed -E "s/^add '(.*)'$/\1/" || true)"
if [[ -n "$staged" ]]; then
  ignored="$(printf '%s\n' "$staged" | while IFS= read -r f; do
              git -C "$STATE_DIR" check-ignore -q "$f" && echo "$f"
            done || true)"
  [[ -z "$ignored" ]] || die "refusing to stage git-ignored files:\n$ignored"
fi
ok "blocked-file verification passed"

# ── 4. Commit (+ push) ─────────────────────────────────────────────────────
if [[ "$NO_COMMIT" == 1 ]]; then
  ok "--no-commit: leaving working tree as-is"
  exit 0
fi

if [[ -z "$(git -C "$STATE_DIR" status --porcelain 2>/dev/null)" ]]; then
  ok "nothing changed since last export — repo already clean"
  exit 0
fi

if ! git -C "$STATE_DIR" config user.email >/dev/null 2>&1; then
  die "git user.email not configured for the private repo. Set it (locally or globally) and re-run."
fi

git -C "$STATE_DIR" add -A
git -C "$STATE_DIR" commit -q -m "sync-export: $(date '+%Y-%m-%d %H:%M') from $(hostname)"
ok "committed: $(git -C "$STATE_DIR" log --oneline -1)"

if [[ "$WANT_PUSH" == 1 ]] || git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
  if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
    msg "pushing to origin..."
    if git -C "$STATE_DIR" push -q origin HEAD 2>/dev/null; then
      ok "pushed to origin"
    else
      warn "push failed (offline? remote missing branch?) — commit is local; push later with:"
      warn "  git -C \"$STATE_DIR\" push origin HEAD"
    fi
  fi
fi

cat <<BANNER

════════════════════════════════════════════════════════════
  Export complete (ADR-08)
    State repo : $STATE_DIR
    SQL dump   : $DUMP_DONE (sanitized; secret tables excluded)
  On the other machine:
    git -C <state-repo> pull
    <sisyphus>/execution-plane/scripts/sync-import.sh
════════════════════════════════════════════════════════════
BANNER
