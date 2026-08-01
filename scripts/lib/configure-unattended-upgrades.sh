#!/usr/bin/env bash
# Configure unattended-upgrades on an Ubuntu/Debian node (run as root).
# Security pocket only; Automatic-Reboot remains false.
# Shared by day-2 SSH (enable-unattended-upgrades.sh) and RKE2 bootstrap.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not available; skipping" >&2
  exit 0
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
