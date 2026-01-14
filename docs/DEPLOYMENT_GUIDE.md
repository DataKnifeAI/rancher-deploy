# Deployment Guide

Complete guide for deploying Rancher clusters on Proxmox using Terraform.

## Prerequisites

- **Proxmox VE 8.0+** with API token access
- **Terraform 1.5+** installed
- **SSH key** for VM authentication (`~/.ssh/id_rsa` recommended)
- **Shell environment**: `bash` or `zsh` (recommended; if using Fish shell, switch to `zsh` for better compatibility with automation scripts and AI tools)
- **Network access** to Proxmox API and GitHub (for RKE2 downloads)
- **Available resources**: 30 vCPU cores, 60GB RAM, 900GB disk space (for manager + 3 apps clusters)

## Quick Start

### 1. Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your Proxmox credentials:

```hcl
proxmox_api_url          = "https://proxmox.example.com:8006/api2/json"
proxmox_api_user         = "terraform@pam"
proxmox_api_token_id     = "terraform-token"
proxmox_api_token_secret = "your-token-secret"
proxmox_node             = "pve"  # Your Proxmox node name

# VM configuration
ssh_private_key = "~/.ssh/id_rsa"
ssh_public_key  = "~/.ssh/id_rsa.pub"

# RKE2 version (IMPORTANT: must be actual released version)
rke2_version = "v1.34.3+rke2r1"  # Check https://github.com/rancher/rke2/tags

# Rancher configuration
rancher_hostname = "rancher.example.com"
rancher_password = "your-secure-password"
install_rancher  = true  # Deploys Rancher automatically in single apply
```

**Critical: RKE2 Version**
- Use specific version tags like `v1.34.3+rke2r1`
- Do NOT use "latest" - it will fail (not a downloadable release)
- Check available versions at https://github.com/rancher/rke2/tags

### 2. Deploy with Logging

From the root directory:

```bash
# Option 1: Using the provided script (recommended)
./scripts/apply.sh -auto-approve

# This creates log file: terraform/terraform-<timestamp>.log

# Option 2: Manual deployment
cd terraform
export TF_LOG=debug TF_LOG_PATH=terraform.log
terraform apply -auto-approve
```

The script will:
- Enable debug logging
- Create timestamped log file
- Show deployment progress
- Display last 50 lines of log after completion

**Deployment Timeline:**
- Cloud image downloads: ~30-60 seconds
- VM creation: ~2-3 minutes
- Cloud-init setup: ~5-7 minutes
- RKE2 installation (Manager): ~5-10 minutes
- Rancher deployment: ~5-10 minutes
- **Downstream cluster registration (NATIVE)**: ~2-3 minutes per cluster
- RKE2 installation (NPRD Apps): ~5-10 minutes
- RKE2 installation (PRD Apps): ~5-10 minutes
- RKE2 installation (POC Apps): ~5-10 minutes
- Democratic CSI deployment (all apps clusters): ~2-3 minutes per cluster
- **Total: 50-70 minutes** (fully automated, no manual steps)

### 3. Monitor Progress

While deployment is running:

```bash
# Watch Terraform output
tail -f terraform/terraform-*.log

# Monitor Proxmox task history
# Via UI: Datacenter → Tasks

# Check VM console
# Via UI: VMs → Select VM → Console
```

### 4. Verify Deployment

```bash
# Check if kubeconfigs were created
ls -la ~/.kube/rancher-*.yaml

# Test cluster access
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get nodes
kubectl get pods -n kube-system

# Check nprd-apps cluster
export KUBECONFIG=~/.kube/nprd-apps.yaml
kubectl get nodes

# Check prd-apps cluster
export KUBECONFIG=~/.kube/prd-apps.yaml
kubectl get nodes

# Check poc-apps cluster
export KUBECONFIG=~/.kube/poc-apps.yaml
kubectl get nodes

# Expected output: 3 nodes in Ready state for each cluster
```

### Optional: Install kubectl Context Switching Tools

To easily switch between the manager and apps clusters, install `kubectx` and `kubens`:

```bash
# Install from project root
make install-kubectl-tools

# Or manually
git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

**Usage examples:**

```bash
# List all cluster contexts
kubectx

# Switch to manager cluster
kubectx rancher-manager

# Switch to apps cluster
kubectx nprd-apps

# Switch back to previous cluster
kubectx -

# List namespaces
kubens

# Switch to a namespace
kubens kube-system

# Switch back to previous namespace
kubens -
```

These tools significantly improve the experience when working with multiple Kubernetes clusters, similar to how `cd` works for directories.

## Advanced Options

### Enable Debug Logging

```bash
# Maximum verbosity
export TF_LOG=trace
./scripts/apply.sh -auto-approve

# Save logs to specific file
export TF_LOG_PATH=my-deployment.log
./scripts/apply.sh -auto-approve
```

### Log Levels

- **trace** - Most verbose, includes all API calls
- **debug** - Detailed information about provider operations
- **info** - General information about deployment progress
- **warn** - Warnings only
- **error** - Errors only

### Plan Before Applying

```bash
cd terraform
terraform plan -out=tfplan

# Review the plan
# Then apply it
terraform apply tfplan
```

### Deployment to Specific Environment

```bash
# Currently single deployment mode, but can be extended
cd terraform
terraform apply -auto-approve
```

## Troubleshooting Deployment

### Deployment Stuck Waiting for RKE2

If deployment hangs at `wait_for_rke2` (4+ minutes):

```bash
# SSH to manager-1 VM
ssh -i ~/.ssh/id_rsa ubuntu@192.168.1.100

# Check RKE2 status
sudo systemctl status rke2-server
sudo journalctl -u rke2-server -n 50

# Force start if needed
sudo systemctl start rke2-server

# Monitor token file
watch 'sudo ls -la /var/lib/rancher/rke2/server/node-token'
```

### RKE2 Installation Fails

**Check version is correct:**
```bash
grep "rke2_version" terraform/main.tf
```

Should show: `rke2_version = "v1.34.3+rke2r1"` (not "latest")

**View installation logs:**
```bash
ssh -i ~/.ssh/id_rsa ubuntu@192.168.1.100
sudo journalctl -u rke2-server | grep -E "INFO|ERROR"
```

**Redeploy with correct version:**
```bash
# Update terraform/main.tf with correct version
cd terraform
rm -f terraform.tfstate*
terraform apply -auto-approve
```

### Network Issues

**Verify cloud-init network configuration:**
```bash
ssh -i ~/.ssh/id_rsa ubuntu@192.168.1.100
ip addr show
cat /etc/netplan/01-netcfg.yaml
cloud-init query
```

**Test connectivity:**
```bash
ping 192.168.1.1       # Test local DNS gateway
ping 1.1.1.1           # Test fallback DNS
ping github.com        # Test DNS and external access
curl https://get.rke2.io | head -5  # Test RKE2 download
```

## Post-Deployment

### Retrieve Kubeconfigs

Automatically created at:
- `~/.kube/rancher-manager.yaml` - Manager cluster
- `~/.kube/nprd-apps.yaml` - Apps cluster
- `~/.kube/.rancher-api-token` - API token file

### Rancher Deployment (Automatic with Single-Apply)

**Fully Automated**: Rancher and downstream cluster registration are completely automated in a single `terraform apply` command!

**What happens automatically:**
1. VMs created and RKE2 installed (~15 minutes)
2. Rancher Manager deployed via Helm (~5-10 minutes)
   - cert-manager installed automatically
   - Rancher deployed with bootstrap password
   - **API token created and saved to `~/.kube/.rancher-api-token`**
3. **Downstream cluster registered using native rancher2 provider** (~2-3 minutes)
   - Cluster object created in Rancher Manager
   - Registration credentials auto-extracted
   - **No manual Rancher UI steps required!**
4. Apps cluster RKE2 installed (~5-10 minutes)
   - Nodes automatically discover Rancher
   - System-agent automatically registers with Rancher
   - Cluster becomes operational without manual configuration

**Deployment sequence:**
```bash
./scripts/apply.sh -auto-approve

# Total time: ~30-50 minutes (includes VMs + RKE2 + Rancher + Downstream Registration)
```

**Technical Implementation:**
- Module: `terraform/modules/rancher_cluster/main.tf` (Helm deployments)
- Provider: `rancher2` (native cluster registration)
- Script: `deploy-rancher.sh` (creates and persists API token)
- Token file: `~/.kube/.rancher-api-token` (for provider authentication)
- IP substitution: `sed 's/127.0.0.1/<real-ip>/g'` in rke2_manager module

**Requirements:**
- `helm` CLI installed (check with `make check-rancher-tools`)
- `kubectl` CLI installed (check with `make check-rancher-tools`)
- Direct access to cluster via kubeconfig path

### Access Rancher UI

```bash
# Get Rancher URL from outputs
terraform output rancher_url

# Open in browser and login:
# Username: admin
# Password: <from rancher_password in tfvars>
```

## Disaster Recovery

### Redeploying Failed Cluster

```bash
cd terraform

# Destroy and redeploy
terraform destroy -auto-approve
rm -f terraform.tfstate*
terraform apply -auto-approve
```

### Keeping VMs, Redeploying RKE2

```bash
# Edit terraform/main.tf and temporarily comment out vm modules
# Keep rke2_* modules
terraform apply -auto-approve

# After RKE2 is deployed, uncomment vm modules
```

## Key Files

| File | Purpose |
|------|---------|
| `apply.sh` | Deploy with automatic logging (root dir) |
| `terraform/main.tf` | Cluster definitions |
| `terraform/provider.tf` | Proxmox provider config |
| `terraform/variables.tf` | Input variables |
| `terraform/terraform.tfvars` | Environment configuration |
| `terraform/modules/proxmox_vm/` | VM creation module |
| `terraform/modules/rke2_cluster/` | RKE2 installation module |

## Environment Variables

### Terraform Logging

```bash
TF_LOG=debug          # Set log level
TF_LOG_PATH=file.log  # Log to file
TF_LOG_CORE=debug     # Core only (less verbose)
```

### Proxmox

```bash
PROXMOX_VE_ENDPOINT          # API endpoint
PROXMOX_VE_API_TOKEN         # API token (id=secret format)
PROXMOX_VE_INSECURE=true     # Skip TLS verification (dev only)
```

## Related Documentation

- [TERRAFORM_VARIABLES.md](TERRAFORM_VARIABLES.md) - Complete variable reference
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues and solutions
- [CLOUD_IMAGE_SETUP.md](CLOUD_IMAGE_SETUP.md) - VM template setup
- [ARCHITECTURE.md](ARCHITECTURE.md) - System design and networking
