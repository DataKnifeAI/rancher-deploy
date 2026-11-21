#!/usr/bin/env bash
# Install stripped Traefik CRD chart as a durable RKE2 user AddOn on apps CPs.
# Does NOT touch rancher-manager (keep stock rke2-traefik-crd there).
#
# Usage: install-crd-chart-apps.sh <ssh_private_key> <cp-ip> [<cp-ip>...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <ssh_private_key> <cp-ip> [<cp-ip>...]" >&2
  exit 1
fi

SSH_KEY="$1"
shift
IPS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/rke2-traefik-crd-no-gateway.yaml"
REMOTE_DIR=/var/lib/rancher/rke2/server/manifests
REMOTE_SKIP="${REMOTE_DIR}/rke2-traefik-crd.yaml.skip"
REMOTE_ADDON="${REMOTE_DIR}/dataknife-rke2-traefik-crd.yaml"

if [ ! -f "$SRC" ]; then
  echo "missing $SRC" >&2
  exit 1
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "missing ssh key: $SSH_KEY" >&2
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no)
FAILED=0

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "Traefik CRD AddOn (no Gateway API): ubuntu@$IP"
  echo "=========================================="
  if ! scp "${SSH_OPTS[@]}" "$SRC" "ubuntu@${IP}:/tmp/dataknife-rke2-traefik-crd.yaml"; then
    echo "✗ scp failed: $IP" >&2
    FAILED=1
    continue
  fi
  if ! ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 0755 "$REMOTE_DIR"
# Ignore packaged chart forever (RKE2 still rewrites the yaml; .skip blocks apply).
touch "$REMOTE_SKIP"
install -m 0644 /tmp/dataknife-rke2-traefik-crd.yaml "$REMOTE_ADDON"
rm -f /tmp/dataknife-rke2-traefik-crd.yaml
ls -la "$REMOTE_SKIP" "$REMOTE_ADDON"
REMOTE
  then
    echo "✗ remote install failed: $IP" >&2
    FAILED=1
    continue
  fi
  echo "✓ $IP"
done

if [ "$FAILED" -ne 0 ]; then
  echo "One or more nodes failed" >&2
  exit 1
fi

echo
echo "Next: kubectl -n kube-system get helmchart,addon | grep -E 'traefik-crd|dataknife'"
echo "Expect HelmChart/Addon dataknife-rke2-traefik-crd; stock rke2-traefik-crd should stay skipped."
