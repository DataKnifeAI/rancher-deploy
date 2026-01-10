# Scripts Directory

This directory contains automation scripts for deploying and managing the Rancher Kubernetes infrastructure.

## Script Categories

### Deployment Scripts

Core infrastructure deployment and management:

- **`apply.sh`** - Terraform plan and apply with automatic logging
- **`destroy.sh`** - Terraform destroy with cleanup and logging

### Rancher Setup Scripts

Rancher-specific configuration and management:

- **`create-rancher-api-token.sh`** - Create Rancher API token for automation
- **`test-rancher-api-token.sh`** - Test Rancher API token functionality
- **`install-system-agent.sh`** - Install Rancher system-agent on downstream cluster nodes
- **`check-agent-status.sh`** - Check cattle-cluster-agent status and troubleshoot DNS issues

### GitHub ARC (Actions Runner Controller) Scripts

GitHub Actions Runner Controller installation and configuration:

- **`install-github-arc.sh`** - Install official GitHub ARC controller and CRDs
- **`setup-github-app-arc.sh`** - Interactive script for GitHub App creation and secret setup
- **`complete-arc-setup.sh`** - Complete ARC setup with existing GitHub App
- **`create-github-app-secrets.sh`** - Create Kubernetes secrets for GitHub App authentication
- **`get-github-app-installation-id.sh`** - Get GitHub App Installation ID using JWT
- **`list-github-apps.sh`** - List GitHub Apps for an organization
- **`suggest-github-app-name.sh`** - Suggest unique GitHub App names to avoid conflicts
- **`generate-jwt.sh`** - Generate JWT for GitHub App authentication

### Storage Setup Scripts

Storage and CSI driver installation:

- **`install-democratic-csi.sh`** - Install Democratic CSI driver for TrueNAS
- **`generate-helm-values-from-tfvars.sh`** - Generate Helm values from Terraform variables

### Database Setup Scripts

Database operator installation:

- **`install-cloudnativepg.sh`** - Install CloudNativePG operator for PostgreSQL

### Utility Scripts

Utility and maintenance scripts:

- **`update-dns-servers.sh`** - Update DNS servers on all deployed VMs

## Usage Examples

### Infrastructure Deployment

```bash
# Deploy infrastructure
./scripts/apply.sh

# Destroy infrastructure
./scripts/destroy.sh
```

### Rancher Setup

```bash
# Create API token
./scripts/create-rancher-api-token.sh https://rancher.example.com admin password

# Install system agent on downstream nodes
./scripts/install-system-agent.sh \
  --rancher-url https://rancher.example.com \
  --rancher-token token-xxxxx:yyyyyy \
  --cluster-id c-abc123 \
  --nodes 192.168.14.110 192.168.14.111
```

### GitHub ARC Setup

```bash
# Interactive setup (recommended)
./scripts/setup-github-app-arc.sh

# Install ARC controller
./scripts/install-github-arc.sh nprd-apps

# Complete setup with existing GitHub App
./scripts/complete-arc-setup.sh
```

### Storage Setup

```bash
# Generate Helm values from Terraform
./scripts/generate-helm-values-from-tfvars.sh

# Install Democratic CSI
export KUBECONFIG=~/.kube/nprd-apps.yaml
./scripts/install-democratic-csi.sh
```

### Database Setup

```bash
# Install CloudNativePG
export KUBECONFIG=~/.kube/nprd-apps.yaml
./scripts/install-cloudnativepg.sh
```

## Script Dependencies

Most scripts require:
- `kubectl` - Kubernetes command-line tool
- `helm` - Helm package manager (for installation scripts)
- `jq` - JSON processor (for some scripts)
- `curl` - HTTP client
- Access to Terraform variables (usually `terraform/terraform.tfvars`)

Some scripts require:
- `gh` CLI - GitHub CLI (for GitHub-related scripts)
- `openssl` - SSL/TLS toolkit (for JWT generation)
- SSH access to cluster nodes (for agent installation)

## Related Documentation

- **[../docs/GITHUB_ARC_SETUP.md](../docs/GITHUB_ARC_SETUP.md)** - Complete GitHub ARC setup guide
- **[../docs/DEMOCRATIC_CSI_TRUENAS_SETUP.md](../docs/DEMOCRATIC_CSI_TRUENAS_SETUP.md)** - TrueNAS storage setup guide
- **[../docs/RANCHER_API_TOKEN_CREATION.md](../docs/RANCHER_API_TOKEN_CREATION.md)** - Rancher API token documentation
