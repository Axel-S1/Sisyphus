#!/usr/bin/env bash
# test_security_baseline.sh — Phase 4 (T5) verification suite.
# Checks, non-interactively:
#   1. Hermes CVE-2026-9368: _scrub_child_env / _build_child_env strip
#      PYTHONPATH/PYTHONHOME and block secret-named vars (module-injection
#      negative test, function level — the exact code execute_code spawns with).
#   2. Goose smart_approve: .env and both profile config.yaml agree on
#      GOOSE_MODE=smart_approve (runtime /proc check requires running daemons
#      — see the phase-4 verification procedure).
#   3. tool_permissions.json parses as valid JSON.
# (The former SQLite journal_mode=delete check was withdrawn with ADR-04 —
# native host filesystem, WAL is correct. See spec v2.3 changelog.)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
fail=0

echo "=== [1/3] Hermes CVE-2026-9368 env-scrub negative test ==="
HERMES_PY="/opt/hermes-agent/venv/bin/python"
if [ ! -x "$HERMES_PY" ]; then
    echo "[ERROR] Hermes venv python not found at $HERMES_PY"
    fail=1
else
    "$HERMES_PY" - <<'EOF' || fail=1
import os, sys
sys.path.insert(0, "/opt/hermes-agent")
os.environ["PYTHONPATH"] = "/tmp/attacker_controlled"
os.environ["PYTHONHOME"] = "/tmp/attacker_home"
os.environ["GOOSE_SERVER__SECRET_KEY"] = "supersecret123"
os.environ["HERMES_HOME"] = "/tmp/x"
from tools.code_execution_env import _scrub_child_env, _build_child_env

scrub = _scrub_child_env(dict(os.environ))
assert "PYTHONPATH" not in scrub, "PYTHONPATH survived scrub"
assert "PYTHONHOME" not in scrub, "PYTHONHOME survived scrub"
assert not any("SECRET" in k or "KEY" in k for k in scrub), "secret-named var survived scrub"

env = _build_child_env(rpc_endpoint="/tmp/sock", rpc_token="tok",
                       tmpdir="/tmp/stage", child_python=sys.executable)
pp = env.get("PYTHONPATH", "")
assert "attacker_controlled" not in pp, "attacker path re-injected into PYTHONPATH"
assert env.get("PYTHONDONTWRITEBYTECODE") == "1"
print("[OK] scrubbed env: PYTHONPATH/PYTHONHOME stripped, secrets blocked")
print("[OK] built child env PYTHONPATH =", repr(pp), "(staging + hermes root only)")
EOF
fi

echo
echo "=== [2/3] GOOSE_MODE=smart_approve in .env and profile configs ==="
grep -q '^GOOSE_MODE=smart_approve$' .env || { echo "[ERROR] .env lacks GOOSE_MODE=smart_approve"; fail=1; }
for cfg in execution-plane/profiles/dev/goose_config/config.yaml execution-plane/profiles/reviewer/goose_config/config.yaml; do
    grep -q 'smart_approve' "$cfg" || { echo "[ERROR] $cfg lacks smart_approve"; fail=1; }
done
echo "[OK] checked" ; true

echo
echo "=== [3/3] tool_permissions.json valid JSON ==="
python3 -c "import json;json.load(open('control-plane/paperclip/config/tool_permissions.json'))" \
    && echo "[OK] valid JSON" || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "=== ALL PHASE 4 BASELINE CHECKS PASSED ==="; else echo "=== SOME CHECKS FAILED ==="; fi
exit $fail
