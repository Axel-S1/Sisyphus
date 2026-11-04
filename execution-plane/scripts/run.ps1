# run.ps1 — Execution Plane bootstrap (Windows / PowerShell equivalent of run.sh).
# Spec: §2.3, §2.4, ADR-01, ADR-03 (symmetric HERMES_HOME + GOOSE_PATH_ROOT),
# ADR-06 (port registry). One server per profile, one port per profile.
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
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
        }
    }
}

# ── ADR-03: symmetric per-profile injection — BOTH vars, hard failure ──
$env:HERMES_HOME     = Join-Path $Root "storage\hermes_data\agent_$Profile"
$env:GOOSE_PATH_ROOT = Join-Path $Root "storage\goose_data\agent_$Profile"
New-Item -ItemType Directory -Force -Path $env:HERMES_HOME, $env:GOOSE_PATH_ROOT | Out-Null
if (-not $env:HERMES_HOME -or -not $env:GOOSE_PATH_ROOT) {
    Write-Error "FATAL: HERMES_HOME / GOOSE_PATH_ROOT not set"; exit 1
}

# Seed the profile config into the engine's isolated root (never overwrite).
$gooseCfgSrc  = Join-Path $Root "execution-plane\profiles\$Profile\goose_config"
$hermesCfgSrc = Join-Path $Root "execution-plane\profiles\$Profile\hermes_config"
if ((Test-Path $gooseCfgSrc) -and (Get-ChildItem $gooseCfgSrc -ErrorAction SilentlyContinue)) {
    $dstDir = Join-Path $env:GOOSE_PATH_ROOT "config"
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    $dstCfg = Join-Path $dstDir "config.yaml"
    if (-not (Test-Path $dstCfg)) {
        Copy-Item (Join-Path $gooseCfgSrc "config.yaml") $dstCfg
    }
}
if ((Test-Path $hermesCfgSrc) -and (Get-ChildItem $hermesCfgSrc -ErrorAction SilentlyContinue)) {
    foreach ($f in Get-ChildItem $hermesCfgSrc) {
        $dst = Join-Path $env:HERMES_HOME $f.Name
        if (-not (Test-Path $dst)) { Copy-Item $f.FullName $dst }
    }
}

# Profile → port lookup (ADR-06 exact registry names: HERMES_PORT_CEo, GOOSE_PORT_DEV, …)
function Get-RegistryPort([string]$prefix, [string]$profile) {
    if ($profile -eq "ceo") { $name = $prefix + "_CEo" }
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
        if (-not $env:API_SERVER_KEY) {
            Write-Error "FATAL: API_SERVER_KEY required (Hermes gateway auth)"; exit 1
        }
        $port = Get-RegistryPort "HERMES_PORT" $Profile
        # Hermes gateway — resident HTTP API (ADR-01 network IPC).
        # Foreground exec: the caller (systemd/launchd/service wrapper) manages the lifecycle.
        & hermes gateway run --port $port
        exit $LASTEXITCODE
    }
    "goose" {
        if (-not (Get-Command goose -ErrorAction SilentlyContinue)) {
            Write-Error "FATAL: 'goose' binary not found on PATH"; exit 127
        }
        if (-not $env:GOOSE_MODE)             { $env:GOOSE_MODE = "smart_approve" }       # never auto (Risk R7)
        if (-not $env:GOOSE_SERVER__HOST)     { $env:GOOSE_SERVER__HOST = "0.0.0.0" }     # host.docker.internal
        if (-not $env:GOOSE_SERVER__PORT)     { $env:GOOSE_SERVER__PORT = Get-RegistryPort "GOOSE_PORT" $Profile }
        if (-not $env:GOOSE_SERVER__SECRET_KEY) {
            Write-Error "FATAL: GOOSE_SERVER__SECRET_KEY required"; exit 1
        }
        # HTTP/WS ACP server — NOT `goose acp` (stdio-only; Risk R9).
        # Foreground exec: the caller (systemd/launchd/service wrapper) manages the lifecycle.
        & goose serve --host $env:GOOSE_SERVER__HOST --port $env:GOOSE_SERVER__PORT
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
