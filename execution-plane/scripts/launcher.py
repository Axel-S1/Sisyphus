#!/usr/bin/env python3
"""
launcher.py — Host Launcher Micro-API (ADR-07)

Lightweight, stdlib-only process-lifecycle manager for the Sisyphus
Execution Plane. Spawns per-profile agent daemons on demand via
execution-plane/scripts/run.sh (which injects the symmetric
HERMES_HOME / GOOSE_PATH_ROOT environment — ADR-03 — and resolves the
per-profile port from the ADR-06 registry), and tears them down after an
idle timeout to release host RAM/CPU.

Endpoints (JSON over HTTP):
    GET  /status                                  — all managed daemons
    POST /launch?profile=<p>&engine=<goose|hermes> — spawn (idempotent)
    POST /shutdown?profile=<p>                    — graceful stop (SIGTERM→SIGKILL)
    POST /touch?profile=<p>                       — mark activity (idle reset)

Idle watchdog: every poll interval, profiles idle longer than
--idle-timeout seconds (default 600 = 10 minutes, per ADR-07) are shut down.
Liveness is REAL-TRAFFIC based: before reaping a daemon that looks idle, the
watchdog probes for established TCP connections on the daemon's port — a
busy agent is never killed even if no client could POST /touch.

Binding (Risk R9 class caution, ADR-07):
    Default bind is 0.0.0.0 so that Paperclip (inside Docker) can trigger
    daemon spawn/shutdown via host.docker.internal:9000. A non-loopback bind
    REQUIRES the `X-Launcher-Secret: <LAUNCHER_SECRET>` header check —
    the launcher hard-fails on startup without a configured secret.

Usage:
    python3 launcher.py [--host 127.0.0.1] [--port 9000]
                        [--idle-timeout 600] [--poll-interval 30]
    env: LAUNCHER_HOST, LAUNCHER_PORT, LAUNCHER_SECRET
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN_SH = os.path.join(REPO_ROOT, "execution-plane", "scripts", "run.sh")
PORTS_ENV = os.path.join(REPO_ROOT, "execution-plane", "scripts", "ports.env")

IDLE_TIMEOUT_DEFAULT = 600   # 10 minutes (ADR-07)
POLL_INTERVAL_DEFAULT = 30   # seconds between watchdog passes
HOOK_INTERVAL_DEFAULT = 600  # 10 min: periodic-hook cadence (cron replacement, ADR-07)

# ── Registry: profile → registered port (parsed from ports.env, ADR-06) ────


def load_port_registry() -> dict:
    """Parse ports.env into {'HERMES_PORT_CEo': 8642, ...}."""
    registry = {}
    try:
        with open(PORTS_ENV) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                registry[key.strip()] = val.strip()
    except FileNotFoundError:
        pass  # launcher still starts; /launch will hard-fail later
    return registry


def port_for_profile(profile: str, engine: str, registry: dict):
    """Resolve the ADR-06 registered port for a profile+engine, or None."""
    prefix = "HERMES_PORT" if engine == "hermes" else "GOOSE_PORT"
    if profile == "ceo":
        key = f"{prefix}_CEo"
    else:
        key = f"{prefix}_{profile.upper()}"
    val = registry.get(key)
    return int(val) if val and val.isdigit() else None

# ── Port liveness ──────────────────────────────────────────────────────────


def port_listening(port: int) -> bool:
    """True if something is LISTENing on the port (host-wide, any bind)."""
    try:
        out = subprocess.run(
            ["ss", "-ltn"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        return f":{port} " in out
    except Exception:
        return False


def port_traffic_since(port: int, since_epoch: float) -> bool:
    """Best-effort activity probe: any TCP connection to the port in the
    last `since_epoch` seconds. Uses `ss -tn` Recv-Q/Send-Q as heuristic —
    a daemon with open established connections is considered active."""
    try:
        out = subprocess.run(
            ["ss", "-tn", "sport", "=", f":{port}"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        return "ESTAB" in out
    except Exception:
        return False

# ── Daemon bookkeeping ─────────────────────────────────────────────────────


class DaemonRegistry:
    """Thread-safe registry of managed subprocesses."""

    def __init__(self):
        self._lock = threading.Lock()
        self._procs = {}   # profile -> {"proc": Popen, "engine": str,
                           #               "port": int, "last_activity": float}

    def get(self, profile):
        with self._lock:
            return dict(self._procs.get(profile) or {})

    def upsert(self, profile, proc, engine, port):
        with self._lock:
            self._procs[profile] = {
                "proc": proc, "engine": engine,
                "port": port, "last_activity": time.time(),
            }

    def all(self):
        with self._lock:
            return {p: dict(v) for p, v in self._procs.items()}

    def touch(self, profile):
        with self._lock:
            if profile in self._procs:
                self._procs[profile]["last_activity"] = time.time()

    def remove(self, profile):
        with self._lock:
            return self._procs.pop(profile, None)


REGISTRY = DaemonRegistry()

# ── Process management ────────────────────────────────────────────────────


def spawn_daemon(profile: str, engine: str, port: int):
    """Start run.sh <profile> <engine> in its own process group."""
    log_path = os.path.join(REPO_ROOT, "storage", f"launcher_{profile}.log")
    log = open(log_path, "ab")
    proc = subprocess.Popen(
        ["bash", RUN_SH, profile, engine],
        stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,   # own process group → clean group kills
        cwd=REPO_ROOT,
    )
    return proc


def shutdown_daemon(profile: str, timeout: float = 10.0):
    """SIGTERM the process group, wait, escalate to SIGKILL."""
    entry = REGISTRY.get(profile)
    proc = entry.get("proc")
    if proc is None:
        return False, f"profile '{profile}' not managed by launcher"
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        REGISTRY.remove(profile)
        return True, "already gone"
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            proc.wait(timeout=5)
        except Exception:
            pass
    REGISTRY.remove(profile)
    return True, "stopped"

# ── Periodic hook (ADR-07: cron replacement) ───────────────────────────────


def hook_runner(script: str, interval: int):
    """Run a host script on a fixed cadence inside the launcher process.

    This is the ADR-07 replacement for cron/systemd timers: the launcher
    already runs as the long-lived execution-plane parent, so it can host
    periodic maintenance hooks (e.g. watchdog-locks.sh). Failures are
    logged and never kill the launcher; a hung hook is killed after half
    the interval."""
    while True:
        time.sleep(interval)
        try:
            subprocess.run(["bash", script],
                           timeout=max(60, interval // 2),
                           check=False, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            print(f"[hook] ran {script}", flush=True)
        except subprocess.TimeoutExpired:
            print(f"[hook] {script} timed out", flush=True)
        except Exception as exc:
            print(f"[hook] {script}: {exc}", flush=True)


# ── Idle watchdog ──────────────────────────────────────────────────────────


def idle_watchdog(idle_timeout: int, poll_interval: int):
    """Every poll: for each managed daemon, if idle longer than the timeout,
    shut it down — UNLESS the daemon is actually serving traffic. Liveness is
    probed with port_traffic_since() (established TCP connections on the
    daemon's port): a busy agent is never reaped, even when no client was
    able to POST /touch (the previous, traffic-blind behaviour). /touch and
    /launch still reset the idle timer for idle-but-expected-busy cases."""
    while True:
        time.sleep(poll_interval)
        now = time.time()
        for profile, entry in list(REGISTRY.all().items()):
            idle = now - entry["last_activity"]
            proc = entry["proc"]
            port = entry["port"]
            if proc.poll() is not None:
                # daemon died on its own — forget it
                REGISTRY.remove(profile)
                continue
            if idle >= idle_timeout:
                if port_traffic_since(port, idle):
                    # real traffic on the daemon's port — busy, not idle
                    REGISTRY.touch(profile)
                    print(f"[watchdog] {profile} idle-timer expired but port "
                          f"{port} is serving traffic — kept alive", flush=True)
                    continue
                print(f"[watchdog] {profile} idle {int(idle)}s "
                      f"(>= {idle_timeout}s, no traffic on :{port}) — "
                      f"shutting down", flush=True)
                ok, msg = shutdown_daemon(profile)
                print(f"[watchdog] {profile}: {msg}", flush=True)

# ── HTTP layer ─────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    server_version = "SisyphusLauncher/1.0"
    launcher_secret = None   # set by serve()

    def _json(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        """Secret required only when bound non-loopback (public trigger)."""
        if not self.launcher_secret:
            return True
        return self.headers.get("X-Launcher-Secret") == self.launcher_secret

    def do_GET(self):
        if urlparse(self.path).path == "/status":
            out = {}
            for profile, entry in REGISTRY.all().items():
                alive = entry["proc"].poll() is None
                out[profile] = {
                    "engine": entry["engine"],
                    "port": entry["port"],
                    "alive": alive,
                    "idle_seconds": int(time.time() - entry["last_activity"])
                    if alive else None,
                }
            self._json(200, {"daemons": out,
                             "registry": load_port_registry()})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._json(401, {"error": "missing/invalid X-Launcher-Secret"})
            return
        url = urlparse(self.path)
        qs = parse_qs(url.query)
        profile = (qs.get("profile") or [None])[0]

        if url.path == "/launch":
            engine = (qs.get("engine") or ["auto"])[0]
            if not profile:
                self._json(400, {"error": "profile query param required"})
                return
            registry = load_port_registry()
            if engine == "auto":
                engine = "goose" if os.path.isdir(os.path.join(
                    REPO_ROOT, "execution-plane", "profiles", profile,
                    "goose_config")) else "hermes"
            port = port_for_profile(profile, engine, registry)
            if port is None:
                self._json(400, {
                    "error": f"no {engine} port registered for '{profile}' "
                             f"(ADR-06 {PORTS_ENV})"})
                return

            existing = REGISTRY.get(profile)
            if existing and existing["proc"].poll() is None:
                REGISTRY.touch(profile)
                self._json(200, {
                    "status": "already-running", "profile": profile,
                    "engine": existing["engine"], "port": existing["port"]})
                return
            if port_listening(port):
                # something else (not spawned by us) already owns the port
                self._json(200, {
                    "status": "foreign-listener",
                    "profile": profile, "engine": engine, "port": port,
                    "note": "port busy but not launcher-managed; "
                            "assume healthy and report"})
                return

            proc = spawn_daemon(profile, engine, port)
            # wait for the daemon to bind its port (up to 30 s)
            deadline = time.time() + 30
            while time.time() < deadline:
                if proc.poll() is not None:
                    self._json(500, {
                        "status": "died", "profile": profile,
                        "engine": engine, "exit_code": proc.returncode,
                        "log": f"storage/launcher_{profile}.log"})
                    return
                if port_listening(port):
                    REGISTRY.upsert(profile, proc, engine, port)
                    self._json(200, {
                        "status": "started", "profile": profile,
                        "engine": engine, "port": port, "pid": proc.pid})
                    return
                time.sleep(0.5)
            self._json(504, {
                "status": "timeout", "profile": profile,
                "note": f"port {port} not listening after 30s; check log"})
            return

        if url.path == "/shutdown":
            if not profile:
                self._json(400, {"error": "profile query param required"})
                return
            ok, msg = shutdown_daemon(profile)
            self._json(200 if ok else 404,
                       {"status": "ok" if ok else "not-found",
                        "profile": profile, "detail": msg})
            return

        if url.path == "/touch":
            if not profile:
                self._json(400, {"error": "profile query param required"})
                return
            if not REGISTRY.get(profile):
                self._json(404, {"error": f"profile '{profile}' not managed"})
                return
            REGISTRY.touch(profile)
            self._json(200, {"status": "ok", "profile": profile})
            return

        self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):   # quiet default access log
        pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(host: str, port: int, idle_timeout: int, poll_interval: int,
          hook_script: str = None, hook_interval: int = HOOK_INTERVAL_DEFAULT):
    Handler.launcher_secret = os.environ.get("LAUNCHER_SECRET") or None
    if host != "127.0.0.1" and not Handler.launcher_secret:
        print("FATAL: non-loopback bind without LAUNCHER_SECRET "
              "(Risk R9/R8 hygiene)", file=sys.stderr)
        sys.exit(2)
    threading.Thread(
        target=idle_watchdog, args=(idle_timeout, poll_interval),
        daemon=True, name="idle-watchdog",
    ).start()
    if hook_script:
        threading.Thread(
            target=hook_runner, args=(hook_script, hook_interval),
            daemon=True, name="periodic-hook",
        ).start()
    print(f"[launcher] listening on http://{host}:{port} "
          f"(idle-timeout={idle_timeout}s, poll={poll_interval}s, "
          f"secret={'on' if Handler.launcher_secret else 'off'})",
          flush=True)
    Server((host, port), Handler).serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--host", default=os.environ.get("LAUNCHER_HOST",
                                                     "0.0.0.0"))
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("LAUNCHER_PORT", "9000")))
    ap.add_argument("--idle-timeout", type=int, default=IDLE_TIMEOUT_DEFAULT)
    ap.add_argument("--poll-interval", type=int, default=POLL_INTERVAL_DEFAULT)
    ap.add_argument("--hook-script", default=None,
                    help="host script run periodically by the launcher "
                         "(ADR-07 cron replacement, e.g. watchdog-locks.sh)")
    ap.add_argument("--hook-interval", type=int, default=HOOK_INTERVAL_DEFAULT)
    args = ap.parse_args()
    serve(args.host, args.port, args.idle_timeout, args.poll_interval,
          args.hook_script, args.hook_interval)


if __name__ == "__main__":
    main()
