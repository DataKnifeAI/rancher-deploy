#!/usr/bin/env bash
# Create .keys/ and generate SSH key for this repo. Do not use host ~/.ssh.
# See docs/ACCESS_SECRETS.md for full details.
#
# Usage: from repo root: ./scripts/setup-keys.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="${REPO_ROOT}/.keys"
KEY_FILE="${KEYS_DIR}/id_rsa"

if [ -d "$KEYS_DIR" ] && [ -f "$KEY_FILE" ]; then
  echo ".keys/ and id_rsa already exist. Exiting."
  exit 0
fi

mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

if [ ! -f "$KEY_FILE" ]; then
  echo "Generating SSH key in .keys/ (ed25519)..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "rancher-deploy"
  chmod 600 "$KEY_FILE"
  chmod 644 "${KEY_FILE}.pub"
  echo "  Created: .keys/id_rsa and .keys/id_rsa.pub"
fi

echo ""
echo "Next steps:"
echo "  1. Add Rancher API token:  echo -n 'YOUR_TOKEN' > .keys/rancher-api-token && chmod 600 .keys/rancher-api-token"
echo "  2. Optional VM recovery:   echo -n 'password' > .keys/vm_recovery_password && chmod 600 .keys/vm_recovery_password"
echo "  3. See docs/ACCESS_SECRETS.md for details."
echo ""
