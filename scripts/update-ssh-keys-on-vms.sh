#!/usr/bin/env bash
# Add a new SSH public key to authorized_keys on existing VMs using the current key.
# Terraform does not update cloud-init/SSH keys on existing VMs (initialization is in ignore_changes).
# If you run this twice with the same key, the key will appear twice in authorized_keys (harmless).
#
# Usage:
#   ./scripts/update-ssh-keys-on-vms.sh CURRENT_PRIVATE_KEY NEW_PUBLIC_KEY SSH_USER IP1 [IP2 ...]
# Example (use repo .keys/, not host ~/.ssh):
#   ./scripts/update-ssh-keys-on-vms.sh .keys/id_rsa .keys/id_rsa_new.pub ubuntu 192.168.14.100 192.168.14.101 192.168.14.102
#
# Get IPs from Terraform (from terraform/ dir):
#   terraform output -json  # then pick node IPs from your config
# Or list manager + nprd + prd + poc node IPs manually.

set -e

if [ $# -lt 4 ]; then
  echo "Usage: $0 CURRENT_PRIVATE_KEY NEW_PUBLIC_KEY SSH_USER IP1 [IP2 ...]"
  echo "Example: $0 .keys/id_rsa .keys/id_rsa_new.pub ubuntu 192.168.14.100 192.168.14.101"
  exit 1
fi

CURRENT_KEY="$1"
NEW_PUBKEY="$2"
SSH_USER="$3"
shift 3
IPS=("$@")

if [ ! -f "$CURRENT_KEY" ]; then
  echo "Error: Current private key not found: $CURRENT_KEY"
  exit 1
fi
if [ ! -f "$NEW_PUBKEY" ]; then
  echo "Error: New public key not found: $NEW_PUBKEY"
  exit 1
fi

FAILED=0

for ip in "${IPS[@]}"; do
  if ssh -i "$CURRENT_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && umask 077 && cat >> ~/.ssh/authorized_keys" < "$NEW_PUBKEY"; then
    echo "OK  $ip"
  else
    echo "FAIL $ip"
    FAILED=1
  fi
done

if [ $FAILED -eq 1 ]; then
  echo "One or more hosts failed. Fix connectivity or key and re-run."
  exit 1
fi
echo "Done. If you changed keys, set ssh_private_key in terraform.tfvars to the new path (or leave empty to use .keys/id_rsa)."
