# Rancher Deploy - Ubuntu 24.04 Cloud Image Setup

**Date**: January 1, 2026  
**Provider**: bpg/proxmox v0.90+  
**OS**: Ubuntu 24.04 (Focal) Cloud Image  

---

## Overview

This Terraform configuration now uses **Ubuntu 24.04 Cloud Images** instead of VM templates. Cloud images provide:

✅ **Fresh, minimal OS** - No template dependencies  
✅ **Automatic provisioning** - Via cloud-init  
✅ **Consistent base** - Same image for all VMs  
✅ **Smaller footprint** - Smaller disk usage  
✅ **Easy updates** - Just change the image URL  

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  Terraform Configuration                    │
├─────────────────────────────────────────────┤
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │ proxmox_virtual_environment_         │  │
│  │   download_file (Ubuntu 24.04)       │  │
│  │                                      │  │
│  │ • Downloads cloud image from:        │  │
│  │   https://cloud-images.ubuntu.com/   │  │
│  │ • Stores in Proxmox datastore        │  │
│  │ • Converts to qcow2 format           │  │
│  └──────────────────────────────────────┘  │
│         ↓ (import_from)                    │
│  ┌──────────────────────────────────────┐  │
│  │ proxmox_virtual_environment_vm       │  │
│  │                                      │  │
│  │ • Creates VM from cloud image        │  │
│  │ • Configures hardware (CPU, RAM)     │  │
│  │ • Sets up networking (IP, VLAN)      │  │
│  │ • Initializes via cloud-init         │  │
│  │   - Sets hostname                    │  │
│  │   - Configures IP address            │  │
│  │   - Sets DNS servers                 │  │
│  └──────────────────────────────────────┘  │
│         ↓ (depends_on)                     │
│  ┌──────────────────────────────────────┐  │
│  │ Running Ubuntu 24.04 VM              │  │
│  │                                      │  │
│  │ • Ready for Rancher installation     │  │
│  │ • SSH access via ubuntu user         │  │
│  │ • cloud-init provisioning complete   │  │
│  └──────────────────────────────────────┘  │
│                                             │
└─────────────────────────────────────────────┘
```

---

## Configuration Changes

### 1. Variables Updated

**Before** (Template-based):
```hcl
variable "vm_template_id" {
  description = "Proxmox VM template ID to clone from"
  type        = number
}
```

**After** (Cloud Image):
```hcl
variable "ubuntu_cloud_image_url" {
  description = "Ubuntu cloud image URL (24.04 focal)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
}
```

### 2. Module Parameters

**Before**:
```hcl
template_id  = var.vm_template_id
storage      = var.clusters["manager"].storage
```

**After**:
```hcl
cloud_image_url = var.ubuntu_cloud_image_url
datastore_id    = var.clusters["manager"].storage
```

### 3. VM Resource Changes

#### Download File Resource (NEW)
```hcl
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "import"
  datastore_id = var.datastore_id
  node_name    = var.proxmox_node
  url          = var.cloud_image_url
  file_name    = "ubuntu-focal-cloudimg-amd64.qcow2"
}
```

**What it does**:
- Downloads Ubuntu 24.04 cloud image from official source
- Stores it in specified Proxmox datastore
- Renames to `.qcow2` format for proper import

#### VM Resource Updates
```hcl
resource "proxmox_virtual_environment_vm" "vm" {
  vm_id           = var.vm_id
  name            = var.vm_name
  node_name       = var.proxmox_node
  stop_on_destroy = true  # NEW: graceful shutdown

  disk {
    datastore_id = var.datastore_id
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id  # CHANGED
    interface    = "virtio0"  # CHANGED from scsi0
    iothread     = true   # NEW: better I/O performance
    discard      = "on"   # NEW: enable TRIM for SSD optimization
    size         = var.disk_size_gb
  }

  depends_on = [proxmox_virtual_environment_download_file.ubuntu_cloud_image]
}
```

**Key differences**:
- `import_from`: Uses downloaded cloud image instead of `clone_id`
- `interface`: `virtio0` (cloud images optimized for virtio)
- `iothread`: Enables multi-threaded I/O for better performance
- `discard`: Enables TRIM for SSD optimization
- `stop_on_destroy`: Graceful shutdown on destroy
- `depends_on`: Ensures image downloaded before VM creation

---

## Ubuntu Cloud Image Details

### Image Source
- **URL**: https://cloud-images.ubuntu.com/focal/current/
- **Format**: `.img` (qcow2 format)
- **Size**: ~2.2 GB (compressed)
- **User**: `ubuntu` (default)
- **Root access**: Via sudo without password

### Version History
```
Ubuntu 24.04 LTS (Focal Fossa)
├─ Standard image (daily updated)
├─ Release date: April 23, 2020
├─ Support until: April 2025 (standard), April 2030 (ESM)
└─ Latest: focal-server-cloudimg-amd64.img
```

### Available Images
```
LTS Releases:
├─ Focal (24.04)       - Current
├─ Jammy (22.04)       - Newer LTS
└─ Noble (24.04)       - Upcoming LTS

Non-LTS Releases:
├─ Mantic (23.10)
├─ Lunar (23.04)
└─ Kinetic (22.10)

Download: https://cloud-images.ubuntu.com/
```

---

## Deployment Steps

### 1. Verify Prerequisites

```bash
# Check Proxmox connectivity
curl -k https://<proxmox-endpoint>:8006/api2/json/version

# Verify datastore space (need ~20+ GB per VM)
ssh root@<proxmox-node> df -h

# Ensure SSH access to Proxmox node
ssh root@<proxmox-node> hostname
```

### 2. Configure Terraform Variables

Create `terraform/environments/production.tfvars`:
```hcl
proxmox_api_url         = "https://192.168.1.10:8006"
proxmox_api_user        = "root@pam"
proxmox_api_token_id    = "terraform"
proxmox_api_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_tls_insecure    = true
proxmox_node            = "pve"

# NEW: Cloud image URL (optional, uses default focal if not set)
ubuntu_cloud_image_url  = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"

clusters = {
  manager = {
    name           = "rancher-manager"
    node_count     = 3
    cpu_cores      = 4
    memory_mb      = 8192
    disk_size_gb   = 50
    domain         = "example.com"
    ip_subnet      = "192.168.1"
    gateway        = "192.168.1.1"
    dns_servers    = ["8.8.8.8", "8.8.4.4"]
    storage        = "local-lvm"
  }
  apps-cluster = {
    name           = "apps-cluster"
    node_count     = 2
    cpu_cores      = 4
    memory_mb      = 8192
    disk_size_gb   = 50
    domain         = "example.com"
    ip_subnet      = "192.168.1"
    gateway        = "192.168.1.1"
    dns_servers    = ["8.8.8.8", "8.8.4.4"]
    storage        = "local-lvm"
  }
}

rancher_version    = "v2.7.7"
rancher_password   = "your-secure-password"
rancher_hostname   = "rancher.example.com"
ssh_private_key    = "~/.ssh/id_rsa"
```

### 3. Initialize Terraform

```bash
cd terraform

# Download providers
terraform init

# Validate configuration
terraform validate

# Plan deployment
terraform plan -var-file="environments/production.tfvars"
```

### 4. Deploy Infrastructure

```bash
# Apply configuration (will download image and create VMs)
terraform apply -var-file="environments/production.tfvars"

# Time: ~5-10 minutes depending on:
# - Internet speed (downloading image)
# - Proxmox performance (importing disk)
# - Number of VMs
```

### 5. Verify Deployment

```bash
# Get cluster IPs
terraform output cluster_ips

# SSH into first manager node
ssh ubuntu@192.168.1.100

# Verify cloud-init completed
sudo cloud-init status

# Check system info
cat /etc/lsb-release
uname -a
```

---

## Cloud-Init Features Configured

### Automatic Configuration

The deployment automatically configures:

**1. User Account**
```yaml
user_account:
  username: "ubuntu"
  # SSH key will be added via Proxmox user configuration
```

**2. Networking**
```yaml
ip_config:
  ipv4:
    address: "192.168.1.100/24"
    gateway: "192.168.1.1"
nameserver: "8.8.8.8 8.8.4.4"
```

**3. Hostname**
```bash
# Set via initialization
hostname = "rancher-manager-1"
domain   = "example.com"
# Result: rancher-manager-1.example.com
```

### Post-Deployment

After deployment, complete:

```bash
# 1. Update system packages
sudo apt update && sudo apt upgrade -y

# 2. Install Docker (for Rancher)
curl https://get.docker.com | sh
sudo usermod -aG docker ubuntu

# 3. Install Rancher
# (Handled by rancher_cluster module or separate playbook)

# 4. Verify cloud-init logs
sudo cloud-init analyze show
sudo cloud-init analyze blame
```

---

## Troubleshooting

### Issue: VM creation hangs at image download

**Symptom**: Terraform stuck for 10+ minutes  
**Cause**: Large image download, slow network

**Solution**:
```bash
# Monitor download on Proxmox node
ssh root@pve tail -f /var/log/pveproxy/access.log

# Check datastore space
df -h /var/lib/vz

# Increase timeout (if needed)
export PROXMOX_VE_TIMEOUT=900
terraform apply
```

### Issue: Cloud-init not running

**Symptom**: VM created but no IP assigned, cloud-init status shows "errors"

**Solution**:
```bash
# Check cloud-init logs
sudo cat /var/log/cloud-init-output.log

# Manually trigger cloud-init
sudo cloud-init clean --all
sudo cloud-init init

# Verify network configuration
sudo cat /etc/netplan/00-installer-config.yaml
```

### Issue: Disk space too small

**Symptom**: "No space left on device" after installing Rancher/Docker

**Solution**:
```hcl
# In terraform.tfvars, increase disk_size_gb
clusters = {
  manager = {
    disk_size_gb = 100  # Increased from 50
  }
}

# Re-apply (doesn't affect existing VMs)
# Must manually expand disk on running VMs:
# 1. Stop VM
# 2. qm disk resize <vmid> scsi0 +50G
# 3. Start VM
# 4. sudo growpart /dev/sda 1
# 5. sudo resize2fs /dev/sda1
```

### Issue: Wrong image version downloaded

**Symptom**: Old Ubuntu version, outdated packages

**Solution**:
```hcl
# Update image URL in terraform.tfvars
ubuntu_cloud_image_url = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"

# Or use specific date
ubuntu_cloud_image_url = "https://cloud-images.ubuntu.com/focal/20240101/focal-server-cloudimg-amd64.img"

# Verify latest available
curl -s https://cloud-images.ubuntu.com/focal/current/ | grep cloudimg-amd64.img
```

---

## Performance Tuning

### Disk Configuration

```hcl
# Current (optimized for cloud images)
disk {
  interface = "virtio0"  # High-performance virtual disk
  iothread  = true       # Multi-threaded I/O
  discard   = "on"       # TRIM support for SSD
  size      = 50         # GB
}

# Alternative for maximum throughput
disk {
  interface = "scsi0"    # SCSI with more features
  iothread  = true
  discard   = "on"
}
```

### Memory & CPU

```hcl
# Rancher Manager (more demanding)
manager = {
  cpu_cores = 4        # Minimum 2, recommended 4
  memory_mb = 8192     # Minimum 4GB, recommended 8GB
}

# Application cluster (less demanding)
nprd-apps = {
  cpu_cores = 4        # Can run with 2 if needed
  memory_mb = 8192     # Can run with 4GB if needed
}
```

### Network Configuration

```hcl
# VLAN support (for network isolation)
network_device {
  bridge = "vmbr0"
  vlan   = 14          # Native VLAN, can be changed per cluster
}

# For production, consider:
# - Separate VLANs per cluster
# - Redundant network bridges
# - QoS limits if on shared hardware
```

---

## Updating the Cloud Image

### Minor updates (same release)

```bash
# The provider automatically downloads latest focal image each run
# No changes needed, just re-apply

terraform apply -var-file="environments/production.tfvars"
```

### Major version upgrade (e.g., 24.04 to 22.04)

```hcl
# Update terraform/variables.tf
variable "ubuntu_cloud_image_url" {
  default = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

# Update terraform.tfvars
ubuntu_cloud_image_url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

# Plan (won't affect existing VMs)
terraform plan -var-file="environments/production.tfvars"

# Manual migration needed:
# 1. Create new VMs with jammy image
# 2. Migrate workloads
# 3. Destroy old focal VMs
```

---

## Security Considerations

### SSH Access

```bash
# Default cloud-init provides password access (less secure)
# For production, configure SSH key:

# 1. In Proxmox, ensure your SSH key is in /root/.ssh/authorized_keys
# 2. Cloud-init will automatically inject your key

# 3. Connect via SSH
ssh ubuntu@<vm-ip>

# 4. Disable password auth (optional)
sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### Image Integrity

```bash
# Verify cloud image checksum
curl -s https://cloud-images.ubuntu.com/focal/current/SHA256SUMS | grep cloudimg-amd64.img

# Calculate local checksum after download
sha256sum focal-server-cloudimg-amd64.img

# Compare against published value
# In production, automate this verification
```

### Network Security

```hcl
# Future: Add Proxmox firewall rules
resource "proxmox_virtual_environment_firewall_rule" "ssh" {
  node_name = var.proxmox_node
  direction = "in"
  action    = "accept"
  protocol  = "tcp"
  dport     = "22"
  log       = true  # Log all SSH attempts
}
```

---

## Cost Analysis

### Storage Requirements

```
Per VM:
- Cloud image (cached): 2.2 GB
- Expanded disk (50 GB): 50 GB
- Overhead: ~2 GB
Total per VM: ~54 GB

Example cluster (5 VMs):
- Total: 270 GB (~0.3 TB)
- Using local-lvm on SSD: Fast, efficient
```

### Deployment Time

```
Timeline:
├─ Image download: 1-3 minutes (depends on internet)
├─ Image import: 2-5 minutes (depends on disk I/O)
├─ VM creation (per VM): 30-60 seconds
├─ Cloud-init initialization: 1-2 minutes
└─ Total for 5 VMs: 8-15 minutes
```

---

## Maintenance

### Regular Tasks

```bash
# Weekly: Check for latest image updates
curl -s https://cloud-images.ubuntu.com/focal/current/ | grep -o 'focal-[^<]*' | sort -u

# Monthly: Update terraform and provider
terraform init -upgrade

# Quarterly: Review Proxmox and Ubuntu LTS updates
```

### Backup Strategy

```bash
# Cloud images are stateless, backup VM data only
# Implement backup policy for:
# - /home (user data)
# - /opt (applications)
# - /etc (configurations)

# Example using Proxmox backup
proxmox-backup-client backup <vm-id> /path/to/data
```

---

## Additional Resources

- **bpg/proxmox Cloud Image Guide**: https://registry.terraform.io/providers/bpg/proxmox/latest/docs/guides/cloud-image
- **Ubuntu Cloud Images**: https://cloud-images.ubuntu.com/
- **Cloud-init Documentation**: https://cloud-init.io/
- **Rancher Documentation**: https://ranchermanager.docs.rancher.com/

---

## Quick Reference

### Deploy fresh cluster
```bash
cd terraform
terraform plan -var-file="environments/production.tfvars"
terraform apply -var-file="environments/production.tfvars"
```

### Get cluster information
```bash
terraform output cluster_ips
terraform output kubeconfig_path
```

### SSH into manager node
```bash
ssh ubuntu@192.168.1.100
```

### Monitor cloud-init
```bash
# On VM
sudo cloud-init status --wait
sudo cloud-init analyze show
```

### Destroy all VMs
```bash
terraform destroy -var-file="environments/production.tfvars"
```

---

**Status**: ✅ Ready for deployment  
**Last Updated**: January 1, 2026  
**Provider**: bpg/proxmox v0.90+
