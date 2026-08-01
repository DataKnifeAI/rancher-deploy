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

wait_for_ssh() {
  local ip="$1"
  local i
  for i in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "ubuntu@$ip" "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_reboot_cycle() {
  local ip="$1"
  local i
  echo "Waiting for $ip to go down and come back after reboot..."
  # Allow reboot to start (SSH may still succeed briefly).
  sleep 20
  for i in $(seq 1 30); do
    if ! ssh "${SSH_OPTS[@]}" "ubuntu@$ip" "true" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ! wait_for_ssh "$ip"; then
    echo "✗ $ip did not return after reboot (~5m)" >&2
    return 1
  fi
  echo "✓ $ip back after reboot"
  return 0
}

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "OS patch: ubuntu@$IP (reboot=$REBOOT)"
  echo "=========================================="
  set +e
  ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y autoremove --purge || true
if [ "$REBOOT" = "true" ] && [ -f /var/run/reboot-required ]; then
  echo "reboot-required present; rebooting in 5s..."
  sync
  nohup bash -c 'sleep 5; reboot' >/dev/null 2>&1 &
  exit 42
fi
if [ -f /var/run/reboot-required ]; then
  echo "NOTE: reboot required on $IP (os_patch_reboot=false — reboot manually after drain)"
else
  echo "No reboot required"
fi
echo "✓ OS patch complete on \$(hostname)"
EOF
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    continue
  fi

  # 42 = reboot requested; 255 often means SSH dropped mid-reboot.
  if [ "$rc" -eq 42 ] || { [ "$REBOOT" = "true" ] && [ "$rc" -eq 255 ]; }; then
    if ! wait_for_reboot_cycle "$IP"; then
      FAILED=$((FAILED + 1))
    fi
    continue
  fi

  echo "✗ OS patch failed on $IP (ssh exit $rc)" >&2
  FAILED=$((FAILED + 1))
done

if [ "$FAILED" -ne 0 ]; then
  echo "OS patch finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "✓ OS patch finished on ${#IPS[@]} node(s)"
