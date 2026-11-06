# run.ps1 — Execution Plane bootstrap (hermes serve / goose serve).
# PowerShell mirror of run.sh (kept logic-identical; syntax-checked only —
# no pwsh on the reference host, still flagged untested).
# Spec: §2.3, §2.4, ADR-01, ADR-03 (symmetric HERMES_HOME + GOOSE_PATH_ROOT),
# ADR-06 (port registry), §5.6. One server per profile, one port per profile.
#
# Usage: powershell -File run.ps1 <profile> [hermes|goose|auto]
param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$Engine = "auto"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Tolerate network problems on an offline host (spec §5.6).
git -C $Root pull --rebase 2>$null | Out-Null

# ── Load secrets (.env) and the ADR-06 port registry (ports.env) ────────
$envFile = Join-Path $Root ".env"
$portsFile = Join-Path $Root "execution-plane\scripts\ports.env"
if (-not (Test-Path $envFile))    { Write-Error "FATAL: $envFile missing (copy .env.example)"; exit 1 }
if (-not (Test-Path $portsFile))  { Write-Error "FATAL: $portsFile missing (copy ports.env.example)"; exit 1 }
foreach ($f in @($envFile, $portsFile)) {
    Get-Content $f | ForEach-Object {
        # strip FULL-LINE and INLINE comments before parsing — otherwise a
        # `KEY=value  # comment` line sets the value to the comment text
        # (bug fixed in the 2026-11-06 sprint; bash `source` strips these
        # automatically, the previous regex did not).
        $line = ($_ -replace '\s*#.*$', '').Trim()
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
        }
    }
}

# ── ADR-03: symmetric per-profile injection — BOTH vars, unconditionally ─
$env:HERMES_HOME     = Join-Path $Root "storage\hermes_data\agent_$Profile"
$env:GOOSE_PATH_ROOT = Join-Path $Root "storage\goose_data\agent_$Profile"
New-Item -ItemType Directory -Force -Path $env:HERMES_HOME, $env:GOOSE_PATH_ROOT | Out-Null

# ── Seed the profile config into the engine's isolated root (never overwrite).
# config.yaml AND permission.yaml are seeded (permission.yaml is the tracked
# tool-level policy source of truth — see the profile file's header).
$gooseCfgSrc  = Join-Path $Root "execution-plane\profiles\$Profile\goose_config"
$hermesCfgSrc = Join-Path $Root "execution-plane\profiles\$Profile\hermes_config"
if ((Test-Path $gooseCfgSrc) -and (Get-ChildItem $gooseCfgSrc -ErrorAction SilentlyContinue)) {
    $dstDir = Join-Path $env:GOOSE_PATH_ROOT "config"
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    $dstCfg = Join-Path $dstDir "config.yaml"
    if (-not (Test-Path $dstCfg)) {
        Copy-Item (Join-Path $gooseCfgSrc "config.yaml") $dstCfg
    }
    $srcPerm = Join-Path $gooseCfgSrc "permission.yaml"
    $dstPerm = Join-Path $dstDir "permission.yaml"
    if ((Test-Path $srcPerm) -and -not (Test-Path $dstPerm)) {
        Copy-Item $srcPerm $dstPerm
    }
}
if ((Test-Path $hermesCfgSrc) -and (Get-ChildItem $hermesCfgSrc -ErrorAction SilentlyContinue)) {
    foreach ($f in Get-ChildItem $hermesCfgSrc) {
        $dst = Join-Path $env:HERMES_HOME $f.Name
        if (-not (Test-Path $dst)) { Copy-Item $f.FullName $dst }
    }
}

# Profile → port lookup (ADR-06 exact registry names: HERMES_PORT_CEO, GOOSE_PORT_DEV, …)
function Get-RegistryPort([string]$prefix, [string]$profile) {
    if ($profile -eq "ceo") { $name = $prefix + "_CEO" }
    else { $name = $prefix + "_" + $profile.ToUpper() }
    $val = [Environment]::GetEnvironmentVariable($name, "Process")
    if (-not $val) {
        Write-Error "FATAL: $name required (ADR-06 port registry)"
        exit 1
    }
    return $val
}

switch ($Engine) {
    "hermes" {
        if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
            Write-Error "FATAL: 'hermes' binary not found on PATH"; exit 127
        }
        # hermes serve is the HTTP backend server (live-verified: JSON-RPC/
        # WebSocket gateway, --port/--host flags). hermes gateway is
        # messaging-platform management — never use it here (Risk R9).
        # Non-loopback binds require Hermes's own auth provider (--insecure
        # is a documented no-op); API_SERVER_KEY stays exported (either name
        # accepted) for adapter credential wiring, but is optional.
        if (-not $env:API_SERVER_KEY) { $env:API_SERVER_KEY = $env:HERMES_API_KEY }
        $port = Get-RegistryPort "HERMES_PORT" $Profile
        & hermes serve --port $port --host "0.0.0.0"
        exit $LASTEXITCODE
    }
    "goose" {
        if (-not (Get-Command goose -ErrorAction SilentlyContinue)) {
            Write-Error "FATAL: 'goose' binary not found on PATH"; exit 127
        }
        if (-not $env:GOOSE_MODE)             { $env:GOOSE_MODE = "smart_approve" }   # never auto (Risk R7)
        if (-not $env:GOOSE_SERVER__SECRET_KEY) {
            Write-Error "FATAL: GOOSE_SERVER__SECRET_KEY required"; exit 1
        }
        # Profile policy: goose 1.56.0 reads permission.yaml from the global
        # ~/.config/goose (no GOOSE_CONFIG_DIR override exists in the binary).
        # GOOSE_ADDITIONAL_CONFIG_FILES (verified present in the binary's
        # config-resolution strings) loads the profile's own policy on top.
        $env:GOOSE_ADDITIONAL_CONFIG_FILES = Join-Path $env:GOOSE_PATH_ROOT "config\permission.yaml"
        # HTTP/WS ACP server — NOT `goose acp` (stdio-only, editor clients;
        # Risk R9). --host/--port are CLI flags: goose 1.56.0 IGNORES the
        # GOOSE_SERVER__HOST/PORT env vars.
        $port = Get-RegistryPort "GOOSE_PORT" $Profile
        & goose serve --host "0.0.0.0" --port $port
        exit $LASTEXITCODE
    }
    "auto" {
        if (Test-Path (Join-Path $Root "execution-plane\profiles\$Profile\goose_config")) {
            & $PSCommandPath $Profile goose
        } else {
            & $PSCommandPath $Profile hermes
        }
        exit $LASTEXITCODE
    }
    default { Write-Error "unknown engine: $Engine"; exit 1 }
}
