#!/usr/bin/env bash
# Day-2: install/configure unattended-upgrades on RKE2 nodes over SSH (idempotent).
# Security pocket only; Automatic-Reboot remains false.
# Usage: enable-unattended-upgrades.sh <ssh_private_key> <ip> [<ip>...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <ssh_private_key> <ip> [<ip>...]" >&2
  exit 1
fi

SSH_KEY="$1"
shift
IPS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="${SCRIPT_DIR}/lib/configure-unattended-upgrades.sh"

if [ ! -f "$LIB_SCRIPT" ]; then
  echo "Missing shared script: $LIB_SCRIPT" >&2
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no)
FAILED=0

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "unattended-upgrades: ubuntu@$IP"
  echo "=========================================="
  # Pipe shared root script over SSH (single source of policy with bootstrap).
  if ! ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <"$LIB_SCRIPT"; then
    echo "✗ unattended-upgrades failed on $IP" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "unattended-upgrades finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "✓ unattended-upgrades finished on ${#IPS[@]} node(s)"
