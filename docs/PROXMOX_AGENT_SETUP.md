# Proxmox Guest Agent Setup

## Current Status

**Issue**: Proxmox guest agent (qemu-guest-agent) is **NOT currently installed** on VMs.

**Current VM Configuration**: `agent: enabled=0` (disabled)

## Changes Made

### 1. Added Agent Block to VM Resource

Updated `terraform/modules/proxmox_vm/main.tf` to enable the Proxmox guest agent:

```hcl
# Enable Proxmox guest agent for better VM management
# This allows Proxmox to get VM status, IP addresses, and perform graceful shutdowns
agent {
  enabled = true
  trim     = true  # Enable fstrim for disk space recovery
  type     = "virtio"
}
```

### 2. Added qemu-guest-agent Installation to Cloud-Init

Updated `terraform/modules/proxmox_vm/cloud-init-rke2.sh` to install and start qemu-guest-agent:

```bash
# ============ INSTALL PROXMOX GUEST AGENT ============
# Install qemu-guest-agent for Proxmox integration
# This enables VM status reporting, graceful shutdowns, and IP address detection
log "Installing Proxmox guest agent (qemu-guest-agent)..."
if ! command -v qemu-guest-agent >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1
    systemctl enable qemu-guest-agent >/dev/null 2>&1
    systemctl start qemu-guest-agent >/dev/null 2>&1
    log "✓ Proxmox guest agent installed and started"
  else
    log "⚠ Could not install qemu-guest-agent (apt-get not available)"
  fi
else
  log "✓ Proxmox guest agent already installed"
  # Ensure it's running
  systemctl enable qemu-guest-agent >/dev/null 2>&1
  systemctl start qemu-guest-agent >/dev/null 2>&1 || true
fi
```

## Benefits of Proxmox Guest Agent

### 1. **VM Status Reporting**
- Proxmox can accurately report VM status (running, stopped, etc.)
- Better monitoring and visibility in Proxmox UI

### 2. **IP Address Detection**
- Proxmox can automatically detect VM IP addresses
- Shows IPs in Proxmox UI without manual configuration

### 3. **Graceful Shutdowns**
- Proxmox can perform graceful shutdowns instead of hard power-off
- Prevents data corruption and ensures clean shutdowns

### 4. **Disk Space Recovery**
- `trim=true` enables fstrim support
- Allows Proxmox to reclaim unused disk space from thin-provisioned disks

### 5. **Better Integration**
- Improved compatibility with Proxmox features
- Better support for VM operations (snapshots, migrations, etc.)

## Impact on Existing VMs

### Existing VMs (401-406)
- **Current**: Agent disabled (`enabled=0`)
- **After apply**: Agent will be enabled in Proxmox config
- **Action needed**: qemu-guest-agent package will be installed on next cloud-init run or manually

### New VMs (407-409 - Workers)
- **Agent**: Enabled from creation
- **Package**: Installed automatically via cloud-init
- **Status**: Ready immediately

## Manual Installation for Existing VMs

If you want to install the agent on existing VMs without recreating them:

```bash
# SSH into each VM
ssh ubuntu@<vm-ip>

# Install qemu-guest-agent
sudo apt-get update
sudo apt-get install -y qemu-guest-agent

# Enable and start the service
sudo systemctl enable qemu-guest-agent
sudo systemctl start qemu-guest-agent

# Verify it's running
sudo systemctl status qemu-guest-agent
```

## Verification

### Check Agent Status in Proxmox UI
1. Go to VM → Hardware → Agent
2. Should show: `enabled=1, fstrim=1, type=virtio`

### Check Agent Status on VM
```bash
ssh ubuntu@<vm-ip>
sudo systemctl status qemu-guest-agent
```

### Verify Agent Communication
In Proxmox UI, check if VM shows:
- Accurate status
- IP address detected automatically
- Can perform graceful shutdown

## Next Steps

1. **Review the plan**: The agent block will be added to all VMs
2. **Apply changes**: `terraform apply hybrid-setup.tfplan`
3. **For existing VMs**: Install qemu-guest-agent manually or wait for next cloud-init run
4. **For new VMs**: Agent will be installed automatically

## Notes

- The agent block in Terraform enables the agent in Proxmox VM config
- The cloud-init script installs the actual qemu-guest-agent package
- Both are needed for full functionality
- Existing VMs may need manual package installation if cloud-init doesn't re-run
