#!/usr/bin/env bash
# setup-sync.sh — Zero-friction multi-machine state sync scaffold (ADR-08).
#
# What it does (idempotent — safe to re-run on every machine):
#   1. Scaffolds the PRIVATE state repo at ~/sisyphus-state/ (or $SISYPHUS_STATE_DIR,
#      or argv[1]) and `git init`s it.
#   2. Seeds a strict private .gitignore: SQLite artifacts, *.sql.gz backups,
#      paperclip_pgdata/, auth locks, and secrets files are NEVER commitable.
#   3. Migrates existing TEXT state out of storage/ into the private repo
#      (first run on a machine that already has agent data) — moves, not copies.
#   4. Creates symlinks from storage/ into the private repo so the daemons
#      read/write their text state directly inside the private repo:
#        storage/hermes_data/agent_*/memories  → ~/sisyphus-state/hermes_data/agent_*/memories
#        storage/hermes_data/agent_*/MEMORY.md → ~/sisyphus-state/hermes_data/agent_*/MEMORY.md
#        storage/goose_data/agent_*/config     → ~/sisyphus-state/goose_data/agent_*/config
#   5. Writes sisyphus-repo.path inside the private repo so sync-import.sh can
#      locate the Sisyphus checkout on the other machine.
#
# The public Sisyphus repo keeps ignoring storage/ wholesale (R8) — the
# symlinks themselves live under already-ignored paths and never pollute
# `git status`. See docs/spec/architecture-spec.md §ADR-08.
#
# Usage:
#   ./execution-plane/scripts/setup-sync.sh [state-dir]
#   SISYPHUS_STATE_DIR=~/somewhere ./execution-plane/scripts/setup-sync.sh
set -euo pipefail

# ── Locate the Sisyphus repo (script lives in execution-plane/scripts/) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STORAGE="$REPO_ROOT/storage"

[[ -d "$STORAGE/hermes_data" && -d "$STORAGE/goose_data" ]] || {
  echo "FATAL: $REPO_ROOT does not look like a Sisyphus checkout (storage/ missing)." >&2
  exit 1
}

command -v git >/dev/null 2>&1 || { echo "FATAL: git not found." >&2; exit 1; }

# ── Resolve the private state dir ──────────────────────────────────────────
STATE_DIR="${1:-${SISYPHUS_STATE_DIR:-$HOME/sisyphus-state}}"
STATE_DIR="${STATE_DIR/#\~/$HOME}"          # expand leading ~
STATE_DIR="$(mkdir -p "$STATE_DIR" && cd "$STATE_DIR" && pwd)"

msg()  { printf '\033[1;34m[setup-sync]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[setup-sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup-sync] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup-sync] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Initialize / adopt the private Git repo ─────────────────────────────
if [[ -d "$STATE_DIR/.git" ]]; then
  ok "private repo already initialized at $STATE_DIR"
else
  if [[ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
    die "$STATE_DIR exists, is not a Git repo, and is not empty — refusing to clobber."
  fi
  git init -b main "$STATE_DIR" >/dev/null 2>&1 \
    || { git init "$STATE_DIR" >/dev/null 2>&1 \
         && git -C "$STATE_DIR" symbolic-ref HEAD refs/heads/main; }
  ok "git init (branch: main) at $STATE_DIR"
fi

# ── 2. Seed the strict private .gitignore (ADR-08 hard exclusions) ─────────
GITIGNORE="$STATE_DIR/.gitignore"
cat > "$GITIGNORE" <<'EOF'
# ── ADR-08 hard exclusions — enforced; sync-export.sh re-verifies pre-commit ──

# Tier 3: ephemeral SQLite state — NEVER commit (binary, unmergeable, churny)
*.db
*.db-wal
*.db-shm
*.sqlite
*.sqlite3
*.sqlite-wal
*.sqlite-shm

# Full-fidelity Paperclip auto-backups contain PLAINTEXT secrets — NEVER commit
*.sql.gz
*.sql.gz.tmp
backups/

# PostgreSQL data dirs — never commit
paperclip_pgdata/

# Secrets hygiene (R8)
.env
ports.env
*.pem
*.key
id_rsa*
auth.lock

# Runtime junk
__pycache__/
*.pyc
.DS_Store
EOF
ok "wrote strict .gitignore (SQLite, *.sql.gz, backups/, pgdata, secrets blocked)"

# ── 3. Seed the private-repo README (what this repo is / is not) ───────────
PRIV_README="$STATE_DIR/README.md"
[[ -f "$PRIV_README" ]] || cat > "$PRIV_README" <<EOF
# sisyphus-state (PRIVATE — do not share)

State-sync repo for the Sisyphus multi-agent system (ADR-08,
docs/spec/architecture-spec.md). Companion checkout: \$(cat sisyphus-repo.path).

Synced here: agent personas/configs, Hermes memories, sanitized Paperclip
SQL dumps (paperclip_exports/). NEVER here: SQLite (*.db), *.sql.gz
auto-backups (plaintext secrets), paperclip_pgdata/ — .gitignore enforces it.

Workflow: on the leaving machine run
  <repo>/execution-plane/scripts/sync-export.sh   (or commit manually)
On the arriving machine run
  git pull && <repo>/execution-plane/scripts/sync-import.sh
EOF

# ── 4. Migrate existing text state out of storage/ (moves, not copies) ─────
# migrate <storage-path> <private-path> <description>
migrate() {
  local src="$1" dst="$2" what="$3"
  [[ -L "$src" ]] && return 0                       # already symlinked
  if [[ -d "$src" ]]; then
    if [[ -d "$dst" ]]; then
      # both sides have content? only a conflict if src has real files
      if [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
        warn "conflict: $what exists BOTH in storage/ and private repo — not merged."
        warn "  manual action: merge $src -> $dst, delete $src, re-run setup-sync.sh"
        return 0
      fi
      rmdir "$src" 2>/dev/null || { warn "cannot remove empty $src — skipping $what"; return 0; }
    elif [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
      mkdir -p "$(dirname "$dst")"
      mv "$src" "$dst"
      ok "migrated $what -> $dst"
    else
      rmdir "$src" 2>/dev/null || true
    fi
  fi
  mkdir -p "$(dirname "$dst")" "$dst"
  return 0
}

shopt -s nullglob
for agent_dir in "$STORAGE"/hermes_data/agent_*; do
  agent="$(basename "$agent_dir")"
  migrate "$agent_dir/memories"   "$STATE_DIR/hermes_data/$agent/memories"   "hermes $agent/memories"
  # MEMORY.md file-level migration (skip if absent)
  if [[ -f "$agent_dir/MEMORY.md" && ! -L "$agent_dir/MEMORY.md" ]]; then
    mkdir -p "$STATE_DIR/hermes_data/$agent"
    if [[ -f "$STATE_DIR/hermes_data/$agent/MEMORY.md" ]]; then
      warn "conflict: hermes $agent/MEMORY.md exists on both sides — not merged."
    else
      mv "$agent_dir/MEMORY.md" "$STATE_DIR/hermes_data/$agent/MEMORY.md"
      ok "migrated hermes $agent/MEMORY.md"
    fi
  fi
done
for agent_dir in "$STORAGE"/goose_data/agent_*; do
  agent="$(basename "$agent_dir")"
  migrate "$agent_dir/config"     "$STATE_DIR/goose_data/$agent/config"      "goose $agent/config"
done
shopt -u nullglob

# ── 5. Create symlinks storage/ → private repo (skip correct existing ones) ─
link_dir() {  # link_dir <storage-path> <private-path>
  local src="$1" dst="$2"
  if [[ -L "$src" ]]; then
    [[ "$(readlink "$src")" == "$dst" ]] \
      && return 0 \
      || warn "relinking $src (pointed at $(readlink "$src"))"
    rm "$src"
  elif [[ -e "$src" ]]; then
    warn "cannot link $src — a real file/dir is still in the way (see migration warnings)."
    return 0
  fi
  mkdir -p "$dst"
  ln -s "$dst" "$src"
  ok "linked $src -> $dst"
}
link_file() {  # link_file <storage-path> <private-path>
  local src="$1" dst="$2"
  if [[ -L "$src" ]]; then
    [[ "$(readlink "$src")" == "$dst" ]] && return 0 || rm "$src"
  elif [[ -e "$src" ]]; then
    warn "cannot link $src — real file in the way (migration conflict?)."
    return 0
  fi
  [[ -f "$dst" ]] || return 0
  ln -s "$dst" "$src"
  ok "linked $src -> $dst"
}

shopt -s nullglob
for agent_dir in "$STORAGE"/hermes_data/agent_*; do
  agent="$(basename "$agent_dir")"
  link_dir  "$agent_dir/memories"  "$STATE_DIR/hermes_data/$agent/memories"
  link_file "$agent_dir/MEMORY.md" "$STATE_DIR/hermes_data/$agent/MEMORY.md"
done
for agent_dir in "$STORAGE"/goose_data/agent_*; do
  agent="$(basename "$agent_dir")"
  link_dir  "$agent_dir/config"    "$STATE_DIR/goose_data/$agent/config"
done
shopt -u nullglob

# exports dir for sync-export.sh
mkdir -p "$STATE_DIR/paperclip_exports"

# ── 6. Record the Sisyphus checkout path inside the private repo ───────────
echo "$REPO_ROOT" > "$STATE_DIR/sisyphus-repo.path"
ok "recorded companion checkout: $REPO_ROOT"

# ── 7. Initial commit (only if identity is configured and repo is fresh) ───
if [[ -z "$(git -C "$STATE_DIR" status --porcelain 2>/dev/null)" ]]; then
  ok "nothing to commit — private repo is clean"
elif [[ -n "$(git -C "$STATE_DIR" log --oneline -1 2>/dev/null)" ]]; then
  warn "uncommitted changes in private repo — leaving them for you (or run sync-export.sh)."
else
  if git -C "$STATE_DIR" config user.email >/dev/null 2>&1; then
    git -C "$STATE_DIR" add -A
    git -C "$STATE_DIR" commit -q -m "chore: scaffold sisyphus-state (ADR-08)"
    ok "created initial commit"
  else
    warn "git user.email not configured — skipping auto-commit."
    warn "  run: git config --global user.email you@example.com, then commit manually."
  fi
fi

# ── Banner ─────────────────────────────────────────────────────────────────
cat <<BANNER

════════════════════════════════════════════════════════════
  sisyphus-state ready (ADR-08)
    Private repo : $STATE_DIR
    Linked into  : $STORAGE/{hermes_data,goose_data}/agent_*/
    Exports dir  : $STATE_DIR/paperclip_exports

  Next steps:
    1. Add your private remote:
       git -C "$STATE_DIR" remote add origin git@github.com:YOU/sisyphus-state.git
    2. Leaving this machine?  ./execution-plane/scripts/sync-export.sh
    3. Arriving elsewhere?    git -C "$STATE_DIR" pull
                              ./execution-plane/scripts/sync-import.sh
  Never commit: *.db, *.sql.gz, backups/, paperclip_pgdata/ (enforced).
════════════════════════════════════════════════════════════
BANNER
