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

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no)
FAILED=0

for IP in "${IPS[@]}"; do
  [ -z "$IP" ] && continue
  echo "=========================================="
  echo "unattended-upgrades: ubuntu@$IP"
  echo "=========================================="
  if ! ssh "${SSH_OPTS[@]}" "ubuntu@$IP" "sudo bash -s" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not available; skipping" >&2
  exit 1
fi

apt-get update -qq
apt-get install -y -qq unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTO

# Security pocket only; no auto-reboot (drain/reboot manually after /var/run/reboot-required).
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UUC'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::DevRelease "auto";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Mail "";
Unattended-Upgrade::MailReport "only-on-error";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
UUC

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl restart unattended-upgrades >/dev/null 2>&1 || true

echo "✓ unattended-upgrades configured on $(hostname) (security only, no auto-reboot)"
EOF
  then
    echo "✗ unattended-upgrades failed on $IP" >&2
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "unattended-upgrades finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "✓ unattended-upgrades finished on ${#IPS[@]} node(s)"
