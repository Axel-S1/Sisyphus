#!/usr/bin/env bash
# install-systemd.sh — install the Execution Plane systemd units.
#
# Substitutes the @@REPO@@ / @@USER@@ placeholders in the template units and
# copies them to /etc/systemd/system/, then reloads the daemon manager.
#
# Usage:
#   sudo ./install-systemd.sh              # uses this repo's root
#   sudo ./install-systemd.sh /path/to/repo
#
# After installation, start instances (profile = instance name):
#   systemctl start goose-serve@dev goose-serve@reviewer hermes-gateway@ceo
set -euo pipefail

REPO="${1:-"$(cd "$(dirname "$0")/../.." && pwd)"}"
RUN_AS="${SUDO_USER:-$(id -un)}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ "$(id -u)" -eq 0 ]] || { echo "run with sudo (needs /etc/systemd/system write access)" >&2; exit 1; }

for unit in "goose-serve@.service" "hermes-gateway@.service"; do
  sed -e "s|@@REPO@@|${REPO}|g" -e "s|@@USER@@|${RUN_AS}|g" \
    "${SRC_DIR}/${unit}" > "/etc/systemd/system/${unit}"
  echo "installed /etc/systemd/system/${unit} (User=${RUN_AS}, REPO=${REPO})"
done

systemctl daemon-reload
echo "daemon-reload done. Start with:"
echo "  systemctl start goose-serve@dev goose-serve@reviewer hermes-gateway@ceo"
