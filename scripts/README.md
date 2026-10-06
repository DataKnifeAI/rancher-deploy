# Scripts Directory

This directory contains automation scripts for deploying and managing the Rancher Kubernetes infrastructure.

## Script Categories

### Deployment Scripts

Core infrastructure deployment and management:

- **`apply.sh`** - Terraform plan and apply with automatic logging
- **`destroy.sh`** - Terraform destroy with cleanup and logging

### Rancher Setup Scripts

Rancher-specific configuration and management:

- **`create-rancher-api-token.sh`** - Create Rancher API token for automation (writes `rancher_api_token` in tfvars; Terraform reads `config/.rancher-api-token` — copy it there; Rancher caps it at 90 days)
- **`test-rancher-api-token.sh`** - Manual curl walkthrough for creating/testing a Rancher API token
- **`setup-rancher-kubeconfig.sh`** - Write kubeconfig entries that log in through the Rancher CLI (`rancher token`) instead of embedding expiring tokens — the standard kubectl setup; see [../docs/CLUSTER_ACCESS_AND_SSO.md](../docs/CLUSTER_ACCESS_AND_SSO.md)
- **`install-system-agent.sh`** - Install Rancher system-agent on downstream cluster nodes
- **`check-agent-status.sh`** - Check cattle-cluster-agent status and troubleshoot DNS issues

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

# kubectl access (recommended): SSO via Authentik SAML (prints a login link) plus
# <cluster>-local break-glass contexts that use the Rancher local user
./scripts/setup-rancher-kubeconfig.sh --install-cli --merge --auth-provider keyCloakProvider --break-glass
kubectl --context prd-apps get nodes   # first call prints a login link, then cached (≤ 90 days)
rancher token delete all               # clear the cache / force re-login

# Local-provider only (e.g. before SAML is configured)
./scripts/setup-rancher-kubeconfig.sh --install-cli --merge

# Install system agent on downstream nodes
./scripts/install-system-agent.sh \
  --rancher-url https://rancher.example.com \
  --rancher-token token-xxxxx:yyyyyy \
  --cluster-id c-abc123 \
  --nodes 192.168.14.110 192.168.14.111
```

### Database Setup

```bash
# Install CloudNativePG
export KUBECONFIG=~/.kube/nprd-apps.yaml
./scripts/install-cloudnativepg.sh nprd-apps
```

## Script Dependencies

Most scripts require:
- `kubectl` - Kubernetes command-line tool
- `helm` - Helm package manager (for installation scripts)
- `jq` - JSON processor (for some scripts)
- `curl` - HTTP client
- Access to Terraform variables (usually `terraform/terraform.tfvars`)

Some scripts require:
- SSH access to cluster nodes (for agent installation)

## Related Documentation

- **[../docs/RANCHER_API_TOKEN_CREATION.md](../docs/RANCHER_API_TOKEN_CREATION.md)** - Rancher API token documentation
- **[../docs/CLUSTER_ACCESS_AND_SSO.md](../docs/CLUSTER_ACCESS_AND_SSO.md)** - kubectl / Rancher SSO access and break-glass
