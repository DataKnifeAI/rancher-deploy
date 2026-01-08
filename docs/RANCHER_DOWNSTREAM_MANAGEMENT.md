# Rancher Downstream Cluster Management

**Last Updated**: January 4, 2026  
**Status**: ✅ **FULLY AUTOMATED** with Manifest-Based Registration

This guide explains how to automatically register downstream (NPRD Apps) clusters with Rancher Manager using Terraform.

## Overview

The deployment provides **end-to-end automated downstream cluster registration** using Rancher's manifestUrl endpoint. When you set `register_downstream_cluster = true` in `terraform.tfvars`, the NPRD Apps cluster will:

1. Deploy 3 RKE2 nodes
2. Configure proper DNS servers  
3. Fetch cluster registration manifest from Rancher API
4. Apply manifest directly via kubectl (includes RBAC, ServiceAccount, Deployment)
5. cattle-cluster-agent pods automatically register with Rancher Manager
6. Cluster automatically becomes operational in Rancher

**Total deployment time**: ~40-50 minutes (VMs + RKE2 + **automatic** Rancher registration)

**No manual Rancher UI steps required!** ✅

## Registration Method: Manifest-Based (NEW - January 4, 2026)

**Changed from**: system-agent-install.sh approach  
**Why**: More reliable, simpler, no external dependencies  
**What improved**: 
- ✅ Eliminates timeout issues with `/v3/connect/agent` endpoint
- ✅ Self-contained manifests (no need to download installation scripts)
- ✅ Automatic CA certificate configuration
- ✅ Works reliably on networks with strict egress controls

### How It Works

1. **Get registration token** from Rancher API: `POST /v3/clusterregistrationtokens`
2. **Fetch manifest** from manifestUrl endpoint: `GET /v3/import/{token}_{cluster-id}.yaml`
3. **Apply manifest** to cluster: `kubectl apply -f -` (includes cattle-cluster-agent deployment)
4. **Pods register automatically**: cattle-cluster-agent pods connect to Rancher and register

### Manifest Contents

The manifest provided by `manifestUrl` includes:

```yaml
# RBAC for cluster agent
- ClusterRole: "cattle-cluster-agent"
- ClusterRoleBinding: "cattle-cluster-agent"

# ServiceAccount and secrets
- ServiceAccount: "cattle" (cattle-system namespace)
- Secret: "cattle-credentials" (token, url, namespace)

# Agent deployment
- Deployment: "cattle-cluster-agent"
  - Image: docker.io/rancher/rancher-agent:v2.13.1
  - Env: CATTLE_SERVER, CATTLE_TOKEN, CATTLE_CA_CHECKSUM
  - Replicas: (distributed across cluster)

# Service for agent pod discovery
- Service: "cattle-cluster-agent"
```

## Quick Start - Fully Automated

### 1. Configure Terraform Variables

Edit `terraform/terraform.tfvars`:

```hcl
# Enable downstream cluster auto-registration
register_downstream_cluster = true

# Rancher hostname (must match DNS and Rancher ingress)
rancher_hostname = "rancher.example.com"

# Ensure correct DNS servers (for internal name resolution)
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]  # Local, Fallback
  }
  nprd-apps = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]  # Local, Fallback
  }
}
```

### 2. Deploy Everything Automatically

```bash
cd /home/lee/git/rancher-deploy
./scripts/apply.sh -auto-approve

# Or manually
cd terraform
terraform apply -auto-approve
```

**What happens automatically (no manual steps):**
1. VMs created (2-3 min)
2. Cloud-init configures networking with proper DNS
3. RKE2 installed on all manager nodes (5-10 min)
4. Rancher deployed via Helm on manager cluster
5. **Rancher API token auto-created** and saved to `config/.rancher-api-token`
6. **Terraform uses API token** to register cluster object in Rancher
7. RKE2 installed on all apps nodes (5-10 min)
8. Rancher system-agent auto-registers all apps nodes
9. **Cluster becomes fully operational** without any manual UI interaction

### 3. Verify Registration

Check Rancher UI → Cluster Management:
- Your cluster should appear as "nprd-apps"
- All 3 nodes should show as "Ready"
- Status should show "Active"

```bash
# Verify from kubectl
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get clusters.management.cattle.io

# Check the registered cluster details
kubectl describe clusters.management.cattle.io nprd-apps
```

## Implementation Details

### How API-Based Registration Works

The downstream cluster registration uses the **Rancher REST API** directly:

```hcl
# In terraform/main.tf:

# 1. Read API token from file
locals {
  rancher_api_token = file("${path.module}/../config/.rancher-api-token")
}

# 2. Register cluster via API call
resource "null_resource" "register_nprd_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      curl -X POST https://${var.rancher_hostname}/v3/cluster \
        -H "Authorization: Bearer ${local.rancher_api_token}" \
        -H "Content-Type: application/json" \
        -d '{
          "name": "nprd-apps",
          "description": "NPRD Apps cluster",
          "type": "rancherkubernetesengine"
        }'
    EOT
  }
}

# 3. Pass registration URL to VMs via cloud-init
module "rke2_apps" {
  rancher_registration_url = curl_response.registration_url.output
}
```

**Workflow:**
```
terraform apply
    ↓
1. deploy-rancher.sh creates API token from local Rancher instance
    ↓
2. Token saved to: config/.rancher-api-token (persistent)
    ↓
3. null_resource provisioner reads token from file
    ↓
4. curl calls Rancher API to create cluster object
    ↓
5. API response includes registration URL
    ↓
6. Registration URL passed to apps VMs via cloud-init env vars
    ↓
7. RKE2 detects env vars during startup
    ↓
8. Automatically installs Rancher system-agent
    ↓
9. System-agent connects to registration URL
    ↓
10. Cluster becomes operational (all nodes Ready, cluster Active)
```

**Key advantages of API-based approach:**
- ✅ **Zero Rancher UI steps** - Everything automated
- ✅ **No provider schema issues** - Direct API calls
- ✅ **Works with all Rancher versions** - v2.7+, v2.8+
- ✅ **Idempotent** - Safe to run `terraform apply` multiple times
- ✅ **Resilient** - Doesn't depend on provider compatibility
- ✅ **GitOps-ready** - Full state tracked in Terraform state file

### Why API-Based (Not rancher2 Provider)?

The `rancher2` Terraform provider has a **schema incompatibility** with modern Rancher:

**Problem:**
- Provider expects `cluster_auth_endpoint` in cluster spec
- Modern Rancher (v2.7+) doesn't use this field
- Causes plan/apply errors

**Example Error:**
```
Error: unexpected fields found in manifest
  cluster_auth_endpoint: field is not known
```

**Solution - API-Based Approach:**
- ✅ Bypass provider schema entirely
- ✅ Call Rancher REST API directly
- ✅ No schema dependencies
- ✅ Works with all modern Rancher versions

### Alternative: Manual Registration (Legacy)

If you prefer manual registration, you can optionally provide credentials manually:

**Status**: ⚠️ Still supported but not recommended (no longer needed)

**When to use:**
- Registering existing clusters (not created by Terraform)
- Manual testing of registration flow
- Debugging registration issues

**Configuration:**
```hcl
# terraform/terraform.tfvars
register_downstream_cluster = true
rancher_registration_token = "pqmgbbjwm67nq5gtzlq54xvblqtx26b6t4sh89kczsvthdg9jn62h4"
rancher_ca_checksum        = "f97575101c793a8407b671c6dcc296867a25c23d286896fd95067955085aedd0"
```

**Disadvantages:**
- ❌ Requires copy/paste of credentials from UI
- ❌ Token expires after 24 hours (need to regenerate)
- ❌ Extra manual steps

**Time**: Same ~40-50 minutes (registration happens same way)

## Configuration Details

### Step 1: Ensure API Token Exists

The API token is automatically created during Rancher deployment:

```bash
# The deploy-rancher.sh script automatically creates and saves the token
ls -la config/.rancher-api-token

# If missing, manually create:
./scripts/create-rancher-api-token.sh
```

**Token file location**: `config/.rancher-api-token` (persisted)

### Step 2: Enable Downstream Registration

Edit `terraform/terraform.tfvars`:

```hcl
# Enable automatic downstream cluster registration
register_downstream_cluster = true

# Rancher configuration
rancher_hostname = "rancher.example.com"
```

**That's all that's required!** The rest is automatic.

### Step 3: Deploy

```bash
cd terraform
terraform apply -auto-approve
```

Terraform will:
1. Create all VMs
2. Install RKE2 on manager
3. Deploy Rancher via Helm
4. **Create cluster object in Rancher** (via API call)
5. **Get registration URL** from Rancher
6. Create all apps VMs
7. Pass registration URL to apps VMs via cloud-init
8. Apps nodes auto-register with Rancher
9. **Cluster becomes fully operational** (~40-50 minutes total)

### DNS Configuration

Both manager and nprd-apps clusters use **local DNS servers**:

```hcl
dns_servers = ["192.168.1.1", "1.1.1.1"]  # Local, Fallback
```

This enables:
- ✅ Resolution of `rancher.example.com` hostname
- ✅ Proper HTTPS certificate validation
- ✅ System-agent download and installation
- ✅ Automatic node registration with Rancher

### API Token Management

**Auto-Creation** (Recommended):
```bash
# Automatically created during Rancher deployment
./scripts/apply.sh
# Creates: config/.rancher-api-token (persistent)
```

**Manual Creation** (If needed):
```bash
./scripts/create-rancher-api-token.sh
```

**Token Verification**:
```bash
# Verify token is valid
./scripts/test-rancher-api-token.sh
```

### Terraform Implementation

**Modules involved:**

1. **deploy-rancher.sh** - Creates API token
   - Authenticates with local Rancher API
   - Creates persistent API token
   - Saves to `config/.rancher-api-token`

2. **null_resource.register_nprd_cluster** - Registers cluster
   - Reads API token from file
   - Calls Rancher API to create cluster
   - Extracts registration URL

3. **rke2_downstream_cluster module** - Configures apps cluster
   - Receives registration URL from Terraform
   - Passes to RKE2 via cloud-init env vars
   - VMs auto-register during RKE2 initialization

### Variables Reference

```hcl
variable "register_downstream_cluster" {
  description = "Enable automatic downstream cluster registration"
  type        = bool
  default     = true  # Enabled by default
}

variable "rancher_registration_token" {
  description = "Token for registration (optional, auto-generated if empty)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "rancher_ca_checksum" {
  description = "CA checksum for HTTPS verification (auto-generated if empty)"
  type        = string
  default     = ""
}
```

## Deployment Workflow

```
terraform apply
├─ Manager cluster deployment (10-15 min)
│  ├─ Create 3 VMs (401-403)
│  ├─ Install RKE2 on manager-1
│  ├─ Join manager-2 and manager-3
│  └─ Deploy Rancher via Helm
│
├─ API Cluster Registration (1 min)
│  ├─ Read API token from config/.rancher-api-token
│  ├─ Call Rancher API to create cluster object
│  ├─ Receive registration URL from API
│  └─ Make registration credentials available
│
└─ Apps cluster deployment (15-20 min)
   ├─ Create 3 VMs (404-406)
   ├─ Cloud-init sets DNS and hosts file
   ├─ Install RKE2 on apps-1
   ├─ RKE2 detects system-agent env vars
   ├─ Auto-install Rancher system-agent
   ├─ System-agent registers with Rancher
   ├─ Join apps-2 and apps-3
   └─ All nodes become Ready

Total Time: ~40-50 minutes (fully automated, zero manual steps)
```

## Verification

After deployment completes:

### 1. Check Rancher UI

```
Rancher UI → Cluster Management
├─ Should see "nprd-apps" cluster
├─ Status should be "Active"
└─ All 3 nodes should show "Ready"
```

### 2. Check from kubectl

```bash
# Manager cluster
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get clusters.management.cattle.io

# Should show nprd-apps cluster
kubectl describe clusters.management.cattle.io nprd-apps
```

### 3. Check apps cluster directly

```bash
# Apps cluster kubeconfig
export KUBECONFIG=~/.kube/nprd-apps.yaml
kubectl get nodes
# Should show all 3 nodes in Ready state

kubectl get pods -n kube-system | grep system-agent
# Should show system-agent pod running on all nodes
```

````

## Troubleshooting

### Issue: "Cluster doesn't appear in Rancher UI"

**Causes & Solutions:**

1. **API token file is missing**
   ```bash
   ls -la config/.rancher-api-token
   # If missing, create it:
   ./scripts/create-rancher-api-token.sh
   ```

2. **Rancher Manager not ready**
   ```bash
   # Check Rancher pods
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get pods -n cattle-system | grep rancher
   # Wait for all pods to be Running
   ```

3. **API call failed**
   ```bash
   # Check terraform logs
   terraform apply -auto-approve 2>&1 | grep -E "curl|error|ERROR"
   # Verify API token is valid
   ./scripts/test-rancher-api-token.sh
   ```

### Issue: "Nodes not registering with Rancher"

**Cause**: System-agent not starting or registration URL not working  
**Solution**:

1. **Check system-agent status**:
   ```bash
   ssh ubuntu@192.168.1.110
   sudo systemctl status rancher-system-agent
   sudo journalctl -u rancher-system-agent -n 50
   ```

2. **Verify DNS resolution**:
   ```bash
   # From apps node:
   nslookup rancher.example.com
   # Should resolve to manager node IP
   ```

3. **Check if environment variables were set**:
   ```bash
   grep -i "system-agent" /var/log/cloud-init-output.log
   env | grep -i rancher
   ```

4. **Manually test registration**:
   ```bash
   # Get registration details from manager
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get clusters.management.cattle.io nprd-apps -o json | \
     jq '.status.token'
   ```

### Issue: "Cluster registration token expired"

**Cause**: Registration tokens are only valid for 24 hours  
**Solution**:

1. **Get new registration token from Rancher API**:
   ```bash
   # This happens automatically in terraform
   # But if you need to do it manually:
   curl -X POST https://rancher.example.com/v3/cluster/c-xxxxx/token \
     -H "Authorization: Bearer $(cat config/.rancher-api-token)" \
     -H "Content-Type: application/json"
   ```

2. **Update terraform variables and reapply**:
   ```bash
   cd terraform
   terraform apply -auto-approve
   ```

### Issue: "DNS not working - can't resolve rancher.example.com"

**Cause**: DNS servers not configured or DNS not available  
**Solution**:

1. **Check current DNS configuration**:
   ```bash
   ssh ubuntu@192.168.1.110
   resolvectl status
   cat /etc/resolv.conf
   ```

2. **Verify DNS servers in Terraform**:
   ```hcl
   # In terraform/terraform.tfvars:
   clusters = {
     nprd-apps = {
       dns_servers = ["192.168.1.1", "1.1.1.1"]
     }
   }
   ```

3. **Test DNS from node**:
   ```bash
   nslookup rancher.example.com
   nslookup 1.1.1.1  # Test fallback
   ```

4. **Manually configure if needed**:
   ```bash
   ssh ubuntu@192.168.1.110
   sudo cat > /etc/resolv.conf << 'EOF'
   nameserver 192.168.1.1
   nameserver 1.1.1.1
   EOF
   ```

### Issue: "API token is invalid or expired"

**Cause**: Rancher API token (from deploy-rancher.sh) has expired or is invalid  
**Solution**:

1. **Verify token file exists and is readable**:
   ```bash
   cat config/.rancher-api-token
   # Should show: token-xxxxx:yyyyy
   ```

2. **Test token validity**:
   ```bash
   ./scripts/test-rancher-api-token.sh
   # If fails, token is invalid
   ```

3. **Recreate token**:
   ```bash
   rm -f config/.rancher-api-token
   ./scripts/create-rancher-api-token.sh
   # Or let Terraform create it:
   terraform apply -auto-approve
   ```

## Advanced Configuration

### Verify Registration via API

To check cluster registration status from CLI:

```bash
# Using Rancher API token
TOKEN=$(cat config/.rancher-api-token)

# List all clusters
curl -k -H "Authorization: Bearer $TOKEN" \
  https://rancher.example.com/v3/cluster

# Check specific cluster
curl -k -H "Authorization: Bearer $TOKEN" \
  https://rancher.example.com/v3/cluster/c-xxxxx

# Check cluster nodes
curl -k -H "Authorization: Bearer $TOKEN" \
  https://rancher.example.com/v3/cluster/c-xxxxx/nodes
```

### Custom Node Labels

To add custom labels during registration, apps VMs receive labels via RKE2 config:

```hcl
# Labels automatically added
labels:
  environment: nprd
  cluster: apps
  deployment: terraform
```

### Monitoring Registration Progress

```bash
# Watch Rancher events
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl logs -n cattle-system -l app=rancher --tail=50 -f

# Check cluster status
kubectl get clusters.management.cattle.io -w

# Monitor system-agent registration
kubectl logs -n cattle-system -l app=rancher-system-agent -f --all-containers

      --etcd --controlplane --worker"
  ]
}
```

### Custom Agent Configuration

Place custom agent config at `/var/lib/rancher/agent` before registration:

```bash
ssh ubuntu@192.168.1.110
sudo mkdir -p /var/lib/rancher/agent

# Create custom agent config
sudo cat > /var/lib/rancher/agent/agent.yaml << 'EOF'
kind: AgentConfig
```

## Disable Automatic Registration

If you want to deploy without automatic registration:

```hcl
# In terraform/terraform.tfvars
register_downstream_cluster = false
```

Then manually register later using manual Rancher UI steps, or re-run with registration enabled later.

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment workflow
- [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md) - API token management
- [DNS_CONFIGURATION.md](DNS_CONFIGURATION.md) - DNS setup for Rancher
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - General troubleshooting guide

## Summary

The **API-based downstream cluster registration** provides:

✅ **Fully automated** - No manual Rancher UI steps  
✅ **Reliable** - No provider schema issues  
✅ **Fast** - 40-50 minutes total deployment time  
✅ **Maintainable** - Simple API calls, easy to debug  
✅ **Flexible** - Works with any Rancher version  
✅ **GitOps-ready** - Everything in Terraform code  

Once complete, you'll have:
- ✅ Rancher Manager cluster (3 nodes)
- ✅ NPRD Apps cluster (3 nodes)
- ✅ Apps cluster automatically registered with Rancher
- ✅ All nodes operational and ready for workloads
- ✅ Full access to both clusters via kubectl

**4. Updated Deployment** (`main.tf`):
- Passes registration variables to nprd-apps nodes
- Primary node executes system-agent installation
- Secondary nodes also get registration parameters (for future enrollment)

### What Gets Automated

When `register_downstream_cluster = true`:

1. ✅ **DNS Configuration**: Nodes get proper DNS servers
2. ✅ **Hosts Entry**: Rancher hostname added to `/etc/hosts`
3. ✅ **RKE2 Installation**: Full Kubernetes cluster deployed
4. ✅ **System-Agent**: Downloaded and installed automatically
5. ✅ **Registration**: Cluster registers with Rancher Manager
6. ✅ **Agent Configuration**: System-agent starts and runs
7. ✅ **RKE2 Components**: Agent downloads necessary binaries
8. ✅ **Cluster Join**: Nodes join as master/worker nodes

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [DNS_CONFIGURATION.md](DNS_CONFIGURATION.md) - DNS setup for Rancher
- [MODULES_AND_AUTOMATION.md](MODULES_AND_AUTOMATION.md) - Terraform module architecture
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues and solutions

## Quick Reference

### Enable downstream registration
```hcl
register_downstream_cluster = true
rancher_registration_token = "token-from-ui"
rancher_ca_checksum = "checksum-from-ui"
```

### Disable downstream registration
```hcl
register_downstream_cluster = false
```

### Update registration credentials
```bash
# Get new token from Rancher UI
# Cluster Management → Add Cluster → Custom
# Copy token and CA checksum

# Update terraform.tfvars
vim terraform/terraform.tfvars

# Redeploy
cd terraform
terraform apply
```

### Check registration status
```bash
# In Rancher UI
# Cluster Management → [Your Cluster] → Machines tab

# Or via kubectl
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get machines -A
```

### Manual registration of existing cluster
```bash
# Retrieve token from Rancher UI
# SSH to apps node
ssh ubuntu@192.168.1.110

# Run registration
curl -kfL "https://rancher.dataknife.net/system-agent-install.sh?token=TOKEN&ca_checksum=CHECKSUM" | sudo sh

# Verify
sudo systemctl status rancher-system-agent
```

---

**Status**: ✅ Ready for Production Use  
**Last Tested**: January 3, 2026  
**Compatibility**: Rancher v2.13.1+, RKE2 v1.34.3+rke2r1, Proxmox VE 8.0+
