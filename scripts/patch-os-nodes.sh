#!/usr/bin/env bash
# Day-2 Ubuntu package patch for RKE2 nodes over SSH.
# Usage: patch-os-nodes.sh <ssh_private_key> <reboot:true|false> <ip> [<ip>...]
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <ssh_private_key> <reboot:true|false> <ip> [<ip>...]" >&2
  exit 1
fi

SSH_KEY="$1"
REBOOT="$2"
shift 2
IPS=("$@")

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no)
FAILED=0

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "OS patch: ubuntu@$IP (reboot=$REBOOT)"
  echo "=========================================="
  if ! ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y autoremove --purge || true
if [ "$REBOOT" = "true" ] && [ -f /var/run/reboot-required ]; then
  echo "reboot-required present; rebooting in 5s..."
  sync
  nohup bash -c 'sleep 5; reboot' >/dev/null 2>&1 &
else
  if [ -f /var/run/reboot-required ]; then
    echo "NOTE: reboot required on $IP (os_patch_reboot=false — reboot manually after drain)"
  else
    echo "No reboot required"
  fi
fi
echo "✓ OS patch complete on \$(hostname)"
EOF
  then
    echo "✗ OS patch failed on $IP" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "OS patch finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "✓ OS patch finished on ${#IPS[@]} node(s)"
