# Phase 4/6 — Security Mitigations (MVP security baseline)

> Spec reference: ADR-02 (§1 emergency patch, §2 MVP approval mode), §5.5
> (`execute_code` patch), §5.7 (`tool_permissions.json`), ADR-04 (SQLite
> `journal_mode: delete`), §2.4 (permission modes).
> Depends on: Phase 2 (daemons) for Goose settings; Phase 3 running for the
> negative tests.

## Objective

Apply the MVP security baseline: neutralize CVE-2026-9368 (RCE via
`PYTHONPATH` → API-key exfiltration), force human approval for destructive
Goose actions (`GOOSE_MODE=smart_approve`), enforce path/command blocking
rules, and eliminate the SQLite WAL-on-virtiofs failure mode
(`DeletedWalGenerationError`).

## Why (risk mapping)

- **R1 (Critical):** Hermes `execute_code` inherits `PYTHONPATH` → an
  attacker-shaped module (`hermes_cli.config`) gets imported and Base64-
  exfiltrates API keys, bypassing stdout redaction.
- **R7 (Critical):** `GOOSE_MODE=auto` without sandbox → destructive
  commands. Sandbox arrives in spec Phase 3 (out of MVP); until then
  `smart_approve` is mandatory.
- **R5:** WAL journal mode on Docker virtual mounts (virtiofs/9p) →
  `DeletedWalGenerationError` → all new sessions blocked.

## Tasks

### 1. Patch Hermes `execute_code` (ADR-02.1 — emergency, before any use)

Implement the environment-sanitization patch in the `execute_code` tool
(subprocess env). Spec §5.5 reference implementation:

```python
import os

_ENV_ALLOWLIST = {"PATH", "HOME", "LANG", "TMPDIR", "VIRTUAL_ENV"}

def _sanitized_env() -> dict:
    """Strict allowlist: neutralizes PYTHONPATH and any module-injection
    vector (CVE-2026-9368)."""
    env = {k: v for k, v in os.environ.items() if k in _ENV_ALLOWLIST}
    env.pop("PYTHONPATH", None)  # redundant, defense in depth
    env["PYTHONPATH"] = ""       # explicitly empty
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env

# subprocess.Popen(..., env=_sanitized_env(), ...)
```

Apply it to **every** subprocess spawned by `execute_code` (not just
Python). Add a startup assertion/log line confirming the sanitized env is
in use. (Locate the tool's source in the installed Hermes; the patch
belongs there, not in this repo, unless the repo vendors Hermes.)

### 2. Enforce `GOOSE_MODE=smart_approve`

- In `profiles/dev/goose_config/` (and any Goose profile), set
  `GOOSE_MODE=smart_approve` in the profile's `config.yaml` (Goose's
  *native* permission mechanism — spec §5.7 caution).
- Confirm the systemd unit / `run.sh` env also carries
  `GOOSE_MODE=smart_approve` (defense in depth; env must not be able to
  downgrade it to `auto` at MVP — if config and env disagree, config wins).

### 3. Write `control-plane/paperclip/config/tool_permissions.json`

```json
{
  "default_mode": "smart_approve",
  "rules": [
    { "pattern": ".*(\\.env|secrets/|id_rsa|\\.ssh/).*", "action": "block" },
    { "pattern": "^rm\\s+-rf\\s+/", "action": "block" },
    { "pattern": "^git push(--force)?\\s+.*main$", "action": "require_approval" },
    { "pattern": "^pytest|^npm test|^cargo test", "action": "allow" }
  ]
}
```

⚠️ Verify this file's schema against the **installed Goose build** first.
If Goose does not support `tool_permissions.json`, express the same policy
in `config.yaml` per-tool permission settings (or a small pre-exec
wrapper). The **policy content** is the durable part: block `.env`,
`secrets/`, `id_rsa`, `.ssh/`, `rm -rf /`; require approval for force-push
to main; allow test runners.

### 4. SQLite `journal_mode: delete` (ADR-04)

For every SQLite DB that lives under `storage/` (Hermes `state.db`, Goose
`sessions.db`, any Paperclip-side DB on a bind mount):

```sql
PRAGMA journal_mode = delete;   -- must return 'delete'
```

Apply it: (a) persistently in each engine's config if supported, else
(b) via a small post-start maintenance script
`execution-plane/scripts/ensure-sqlite-modes.sh` that runs the PRAGMA
against every DB file found under `storage/hermes_data/**` and
`storage/goose_data/**`, and (c) wire that script into the systemd units
(`ExecStartPre=`) or a timer. On native Linux filesystems WAL may remain,
but for MVP uniformity enforce `delete` everywhere under `storage/`.

### 5. Verification tests

- `PYTHONPATH` negative test (spec §8): from a Hermes `execute_code` call,
  run `python3 -c "import hermes_cli"` (or the injection-shaped import) —
  it **must fail**; also dump `os.environ` from inside `execute_code` and
  assert `PYTHONPATH` is empty.
- Permission negative test: ask the dev-profile Goose to read `.env` →
  must be **blocked**; to run `pytest` → allowed; to `rm -rf /` → blocked;
  to push to `main` → approval required.
- `PRAGMA journal_mode` returns `delete` for every DB on `storage/`.

## Acceptance criteria

- [ ] `execute_code` subprocess env is allowlisted; `PYTHONPATH` empty;
      module-injection import fails from within it.
- [ ] All Goose profiles run with `GOOSE_MODE=smart_approve` (verify in
      daemon env: `systemctl show goose-serve@dev -p Environment` or
      `/proc/<pid>/environ`).
- [ ] `tool_permissions.json` (or `config.yaml` equivalent) installed and
      negative tests pass (`.env` blocked, `rm -rf /` blocked, push→main
      requires approval, `pytest` allowed).
- [ ] Every SQLite DB under `storage/` reports `PRAGMA journal_mode = delete`.
- [ ] A destructive-action request through the full pipeline (Paperclip →
      adapter → Goose) surfaces a human-approval prompt, not silent
      execution.

## Common pitfalls

- Patching only the Python subprocess path of `execute_code` (shell
  invocations bypass it) — sanitize every spawn.
- Relying on an unverified `tool_permissions.json` schema — test it, and
  fall back to `config.yaml` rules if unsupported.
- Forgetting the watchdog script won't fix DBs created *after* it ran —
  make it idempotent and scheduled, or set the PRAGMA at connection setup
  in each engine.

## Outputs for next phase

Phase 5 adds reliability (watchdog + backoff) and assumes the security
baseline is stable; no security regressions may be introduced there.
