# Phase 4/6 — Security Mitigations (MVP security baseline)

> Status: **Plan** (not yet executed — re-opened by the 2026-11-06
> Refactoring & Security Sprint; an earlier aborted run left partial
> artifacts — a tracked `permission.yaml` policy and the env-scrub already
> present in the installed Hermes build — but **no acceptance criterion has
> been verified**). Spec reference: ADR-02 (§1 emergency patch, §2 MVP
> approval mode), §5.5 (`execute_code` patch), §5.7 (tool permissions),
> §2.4 (permission modes). *ADR-04 (SQLite journal modes) was withdrawn in
> the sprint — see the spec.* Depends on: Phase 2 (daemons) for Goose
> settings; Phase 3 running for the negative tests.

## Objective

Apply the MVP security baseline: neutralize CVE-2026-9368 (RCE via
`PYTHONPATH` → API-key exfiltration), force human approval for destructive
Goose actions (`GOOSE_MODE=smart_approve`), and enforce path/command
blocking rules. *(The former "SQLite `journal_mode: delete`" task was
withdrawn with ADR-04 — the Execution Plane runs natively on the host
filesystem, where WAL is correct.)*

## Why (risk mapping)

- **R1 (Critical):** Hermes `execute_code` inherits `PYTHONPATH` → an
  attacker-shaped module (`hermes_cli.config`) gets imported and Base64-
  exfiltrates API keys, bypassing stdout redaction.
- **R7 (Critical):** `GOOSE_MODE=auto` without sandbox → destructive commands.
  Sandbox arrives post-MVP (spec Phase 3); until then `smart_approve` is
  mandatory.

## Verified environment facts (from Phases 1–3, 2026-11-04)

- `GOOSE_MODE=smart_approve` is already present in the host `.env` **and**
  seeded into every profile's `config.yaml` (Phase 2). Remaining work:
  verify it reaches each daemon's runtime env (`/proc/<pid>/environ`).
- The daemons are spawned on demand by the Host Launcher (`launcher.py`,
  port 9000) via `run.sh`; there are no systemd units (ADR-07). Any
  post-start hook must be wired into `run.sh`/`launcher.py`, not systemd.
- The Paperclip container (`paperclip_control_plane`) and PostgreSQL
  (`paperclip_postgres`) are running; host :3000→container :3100.
  Paperclip is in `authenticated` mode, `bootstrap_pending` (one-time human
  onboarding at <http://localhost:3000> still pending) — the Paperclip-side
  negative permission tests may need that bootstrap first.
- goose serve's ACP route (`/acp`, `X-Secret-Key` header) is the validated
  integration point for permission tests against the dev profile.
- Goose builds: sessions/config SQLite lives under
  `storage/goose_data/agent_<profile>/` (via `GOOSE_PATH_ROOT`); Hermes state
  under `storage/hermes_data/agent_<profile>/` (via `HERMES_HOME`).

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
    env.pop("PYTHONPATH", None)  # stripped — never re-added (CVE-2026-9368)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env

# subprocess.Popen(..., env=_sanitized_env(), ...)
```

Apply it to **every** subprocess spawned by `execute_code` (not just Python)
— shell invocations bypass a Python-only patch. Add a startup log line
confirming the sanitized env is in use. Locate the tool's source in the
installed Hermes; the patch belongs there (or in a vendored copy) — not in
this repo's scripts.

### 2. Enforce `GOOSE_MODE=smart_approve` end-to-end

- `.env` and both profile `config.yaml`s already set `smart_approve`
  (Phase 2). Verify at runtime: launch via the launcher and inspect
  `/proc/<pid>/environ` for the goose serve process — env and config must
  agree, and **config wins** over env (if they disagree, config is
  authoritative at MVP; env may not downgrade to `auto`).

### 3. Write `control-plane/paperclip/config/tool_permissions.json`

Target policy (durable content; schema to be validated against the installed
goose 1.56.0 build first — Goose's native mechanism is `config.yaml`
permission settings; if `tool_permissions.json` is not supported, express the
same rules there):

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

### 4. Verification tests

- **PYTHONPATH negative test:** from a Hermes `execute_code` call, run
  `python3 -c "import hermes_cli"` (or the injection-shaped import) — it
  **must fail**; also dump `os.environ` from inside and assert `PYTHONPATH`
  is absent (the deployed build's trusted re-injection —
  `/tmp/stage:/opt/hermes-agent` — is the only allowed exception, see
  spec §5.5).
- **Permission negative tests:** ask the dev-profile Goose to read `.env` →
  **blocked**; run `pytest` → allowed; `rm -rf /` → blocked; push to `main`
  → approval required. *(Note: `pytest` allow and the pattern blocks are not
  expressible in goose's tool-name-level `permission.yaml` — the negative
  tests validate the transitive gating (`shell`/`read` in `ask_before`)
  until the wrapper enforcement layer exists.)*

## Acceptance criteria

- [ ] `execute_code` subprocess env is allowlisted; `PYTHONPATH` absent
      (trusted re-injection per spec §5.5 allowed); module-injection import
      fails from within it.
- [ ] All Goose profiles run with `GOOSE_MODE=smart_approve` (verify in
      daemon runtime env via `/proc/<pid>/environ`).
- [ ] Tool-permission policy installed (`permission.yaml` + the
      `tool_permissions.json` pattern contract) and negative tests pass
      (`.env` blocked, `rm -rf /` blocked, push→main approval, `pytest`
      allowed — pattern rules via the wrapper layer).
- [ ] A destructive-action request through the full pipeline (Paperclip →
      adapter → Goose) surfaces a human-approval prompt, not silent
      execution. *(Requires the Paperclip one-time onboarding to be done —
      human step at <http://localhost:3000>. If not yet done, test the
      adapter→Goose leg directly and note the deferral.)*

## Common pitfalls

- Patching only the Python subprocess path of `execute_code` — sanitize
  every spawn.
- Relying on an unverified `tool_permissions.json` schema — test it, fall
  back to `config.yaml` rules if unsupported.
- Hard-coding the illustrative watchdog table names — the real Paperclip
  schema is `issues`/`heartbeat_runs`/`routine_runs` (Phase 3 finding).
- Forgetting DBs created after the script ran — keep the hook idempotent
  and scheduled.
- Wiring post-start hooks into systemd — systemd is deprecated by ADR-07;
  use `run.sh` / launcher hooks.

## Outputs for next phase

Phase 5 adds reliability (watchdog + backoff) and assumes the security
baseline is stable; no security regressions may be introduced there.
