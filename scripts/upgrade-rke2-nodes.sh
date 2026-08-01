#!/usr/bin/env bash
# Day-2 in-place RKE2 upgrade over SSH (one node at a time, no automatic drain).
# Usage: upgrade-rke2-nodes.sh <ssh_private_key> <rke2_version> <ip> [<ip>...]
#
# Prefer draining/cordoning control-plane and workers yourself before enabling
# terraform enable_rke2_upgrade. This script only runs the official installer
# with INSTALL_RKE2_VERSION and restarts the appropriate unit.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <ssh_private_key> <rke2_version> <ip> [<ip>...]" >&2
  exit 1
fi

SSH_KEY="$1"
RKE2_VERSION="$2"
shift 2
IPS=("$@")

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no)
FAILED=0

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "RKE2 upgrade: ubuntu@$IP -> $RKE2_VERSION"
  echo "=========================================="
  if ! ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <<EOF
set -euo pipefail
TARGET="$RKE2_VERSION"
CURRENT=\$(/usr/local/bin/rke2 --version 2>/dev/null | awk '{print \$3}' || true)
echo "Current: \${CURRENT:-unknown}  Target: \$TARGET"
if [ -n "\$CURRENT" ] && [ "\$CURRENT" = "\$TARGET" ]; then
  echo "✓ Already on \$TARGET"
  exit 0
fi
INSTALLER=/tmp/rke2-installer-upgrade.sh
curl -sfL --max-time 60 https://get.rke2.io -o "\$INSTALLER"
chmod +x "\$INSTALLER"
INSTALL_RKE2_VERSION="\$TARGET" "\$INSTALLER"
systemctl daemon-reload
if systemctl list-unit-files | grep -q '^rke2-server.service'; then
  systemctl restart rke2-server
  echo "✓ Restarted rke2-server"
elif systemctl list-unit-files | grep -q '^rke2-agent.service'; then
  systemctl restart rke2-agent
  echo "✓ Restarted rke2-agent"
else
  echo "⚠ No rke2-server/agent unit found" >&2
  exit 1
fi
echo "✓ RKE2 upgrade command completed on \$(hostname)"
EOF
  then
    echo "✗ RKE2 upgrade failed on $IP" >&2
    FAILED=$((FAILED + 1))
  else
    # brief settle between nodes
    sleep 15
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "RKE2 upgrade finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "✓ RKE2 upgrade finished on ${#IPS[@]} node(s)"
