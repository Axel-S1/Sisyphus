# Addendum — Multi-Machine State Sync (ADR-08) — **Implementation Record** ✅

> Status: **Complete and E2E-validated** (commits `c8879c0` → `9682d67` →
> `cfde19f`; private repo `0af12f1`, re-export `e855563`). Executed
> 2026-11-08, out of sequence (between Phase 3 and Phase 4) after the
> architecture was upgraded to v2.4 mid-flight. Spec reference: **ADR-08**,
> R8 (secrets hygiene). This is an **addendum**, not one of the six MVP
> sub-phases.

## Objective

Prove the architecture is **100% reproducible from scratch**: any machine
that can clone the public repo and pull the private state repo must reach a
fully operational state with zero manual state work — and prove it by
wiping the local workspace and running the full rebirth cycle.

## What was built

### `execution-plane/scripts/setup-sync.sh` (ADR-08 scaffold — idempotent)

- Adopts (never clobbers) the private repo at `~/sisyphus-state/`
  (or `$SISYPHUS_STATE_DIR`); `git init -b main` only if the directory is
  empty or absent — **dies** if it exists, is not a git repo, and is not empty.
- Seeds the strict private `.gitignore` (ADR-08 hard exclusions): all SQLite
  artifacts (`*.db`, `-wal`, `-shm`, `*.sqlite*`), `*.sql.gz`, `backups/`,
  `paperclip_pgdata/`, secrets files (`.env`, `ports.env`, `*.pem`, `*.key`,
  `id_rsa*`, `auth.lock`), runtime junk.
- **Migrates text state out of `storage/`** (moves, not copies) on first run:
  `hermes_data/agent_*/memories`, `MEMORY.md`, `goose_data/agent_*/config`.
- Creates the `storage/ → ~/sisyphus-state/` **symlinks** so daemons
  read/write their text state directly inside the private repo; detects and
  skips/warns on conflicts instead of merging blindly.
- Records the companion checkout path (`sisyphus-repo.path`) inside the
  private repo so `sync-import.sh` can locate the Sisyphus checkout elsewhere.

### `execution-plane/scripts/sync-export.sh` (sanitized, FK-repaired export)

1. Locates the private state repo (override → default → symlink discovery).
2. Runs a **sanitized `pg_dump`** of Paperclip PostgreSQL
   (`--exclude-table-data` for `company_secrets`, `company_secret_versions`,
   `agent_api_keys`, `ai_connection_pools`, `user_secret_definitions`;
   `account` **is kept** — salted Argon2id hashes, logins survive).
3. **FK repair in the pipeline** (v2.4 amendment): runs `repair-dump.py`
   after the sanitization proof and **before** the checksum. The committed
   dump is therefore import-ready **by construction**.
4. Verifies no blocked files are tracked/staged in the private repo, commits
   (`sync-export: <date> from <host>`), and pushes if a remote is configured
   (offline tolerated).

### `execution-plane/scripts/repair-dump.py` (FK-action emulation)

Parses the dump's own schema (`ADD CONSTRAINT … FOREIGN KEY …`) to find every
table/column referencing an **excluded** secret table, then rewrites the COPY
data emulating the FK action:

| FK action on the excluded table | Repair applied to the referencing row |
|---|---|
| `ON DELETE CASCADE` | row dropped |
| `ON DELETE SET NULL` | column nulled |
| `RESTRICT` / `NO ACTION` | column nulled (documented deviation — the referenced rows were already excluded) |

### `execution-plane/scripts/sync-import.sh` (gated restore)

- **Gates (all hard-fail)**: dump exists; checksum matches; **no
  secret-table rows** in the dump (tamper defense, R8); Paperclip container
  **down**; PostgreSQL **up**.
- Drops **both** `public` **and** `drizzle` schemas before restoring (the
  `drizzle` migration-bookkeeping schema from a previous restore otherwise
  collides with the dump's `CREATE SCHEMA drizzle`).
- Restores, then reports post-restore counts (`user`, `companies`) and
  reminds that excluded keys need re-entry in the Paperclip UI.
- Warns on dirty private-repo state and behind-origin pulls (consistency
  model: async, last-writer-wins — see spec ADR-08).

## Clean-slate E2E validation (2026-11-08)

Full purge-and-rebirth executed against the live stack:

| Step | Command | Result |
|---|---|---|
| 0 | Backup pre-flight | ✅ private repo verified: dump 2.2M + checksum OK, goose configs tracked, commit `8378a2a` |
| 1 | `./stop.sh` | ✅ containers + network removed, launcher stopped; **operator desktop Goose preserved** (env-based repo-managed check) |
| 2 | Wipe `storage/` + `execution-plane/workspace/` to `.gitkeep` scaffolding | ✅ (incl. root-owned `paperclip_pgdata/` via sudo; `.gitkeep` restored via `git checkout` after an over-eager `rm -rf`) |
| 3 | `./execution-plane/scripts/setup-sync.sh` | ✅ adopted existing private repo, re-seeded `.gitignore`, rebuilt all symlinks, zero conflicts |
| 4 | `./start.sh` | ✅ launcher :9000 + **brand-new PostgreSQL volume** + Paperclip up |
| 5 | `docker compose stop paperclip` + `sync-import.sh --yes` | ✅ checksum + sanitization gates passed; restore complete: **users=3, companies=2** |
| 6 | `docker compose up -d paperclip` + `test_container_connectivity.sh` | ✅ **all green**: container→host gateway 401/authenticated, full ACP `initialize` handshakes on dev (:3284) **and** reviewer (:3285) with goose 1.56.0, negative-auth 401, clean teardown |

> **Test-output note (DX)**: `test_container_connectivity.sh` is
> self-quieting — it redirects all output to `/tmp/phase3_conn_test.log`.
> An empty terminal does **not** mean it failed; read the log.

## Defects found by the validation (and fixed)

| # | Defect | Root cause | Fix |
|---|---|---|---|
| 1 | Restore aborted: FK violation `company_secret_bindings_secret_id_company_secrets_id_fk` (+ 2,515 orphaned `secret_access_events`) | `--exclude-table-data` keeps secret-table *schema* but leaves rows in referencing tables pointing at excluded ids | **Export-side**: `repair-dump.py` integrated into `sync-export.sh` before checksum (`cfde19f`) |
| 2 | Second restore attempt died on `schema "drizzle" already exists` | `sync-import.sh` dropped `public` only; `drizzle` survived the first partial restore | `sync-import.sh` now drops both `public` and `drizzle` (`cfde19f`) |
| 3 | `grep: unrecognized option '-- Dumped…'` | dump-date probe passed the pattern as an option | `grep -e` (`cfde19f`) |

Defect #1 is the architecturally significant one: sanitization (R8) and
importability were in latent conflict — the private repo would happily hold
a dump no machine could restore. The export side is now the single place
that guarantees both.

## Deviations from the original plan

| Plan | As-built | Reason |
|---|---|---|
| Repair logic conceptually "import-side" | **Export-side** (in `sync-export.sh`, pre-checksum) | Operator decision 2026-11-08: the committed `.sql` must be 100% clean and importable without manipulation |
| `paperclip_pgdata/` wiped by user-level commands only | Required `sudo` (container-owned `999:root` dir) | Documented expectation for operators running the purge |
| `find … ! -name .gitkeep -exec rm -rf` keeps `.gitkeep` | It doesn't (rm -rf on the parent dir removes them) | Recovered via `git checkout -- storage/`; the purge procedure now documents `git checkout -- storage/` as the last step |

## Outputs consumed by later phases

- Phase 4/5/6 assume the stack can be rebuilt from scratch at any time —
  this addendum makes that a verified property instead of an assumption.
- Phase 6's E2E report should reference this record for the state-sync leg
  of Go/No-Go.
- Secret re-entry after any import remains an operational prerequisite
  (R8 by design) — provider/agent keys are never synced.
