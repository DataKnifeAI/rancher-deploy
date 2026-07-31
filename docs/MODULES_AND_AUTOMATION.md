# Terraform Rancher Deployment - Complete Setup

## Overview

The rancher-deploy project provides **end-to-end automation** for deploying Rancher on Proxmox using Terraform. This includes:

1. **VM Provisioning** - bpg/proxmox provider
2. **RKE2 Installation** - Automated Kubernetes bootstrapping
3. **Rancher Deployment** - Helm-based installation
4. **Cluster Registration** - Manifest-based downstream cluster registration (NEW)

## Modules

### 1. proxmox_vm Module
**Location:** `terraform/modules/proxmox_vm/`

Creates VMs on Proxmox with cloud-init configuration:
- Automatic OS provisioning from Ubuntu cloud images
- Network configuration (IP, DNS, hostname)
- SSH key injection for authentication
- VLAN tagging and gateway configuration

### 2. rke2_manager_cluster Module
**Location:** `terraform/modules/rke2_manager_cluster/main.tf`

Installs RKE2 on manager cluster nodes:
- Configures primary server node (cluster initialization)
- Joins additional servers in HA mode (via port 9345)
- Retrieves kubeconfig to ~/.kube/rancher-manager.yaml
- Validates cluster health before proceeding

**Key Features:**
- Automatic HA token generation
- Zero-downtime multi-node setup
- Kubeconfig management
- Kubernetes API readiness verification

### 3. rancher_cluster Module
**Location:** `terraform/modules/rancher_cluster/main.tf`

Deploys Rancher on manager cluster via Helm:
- Installs cert-manager for TLS
- Deploys Rancher via Helm chart
- Configures bootstrap password
- Sets up Ingress for HTTPS access
- **Creates and persists API token** to ~/.kube/.rancher-api-token

**Key Features:**
- Automatic namespace creation (cattle-system)
- TLS certificate support
- Multi-replica Rancher deployment
- API token generation and persistence
- Rancher API endpoint availability verification

### 4. rke2_downstream_cluster Module
**Location:** `terraform/modules/rke2_downstream_cluster/main.tf`

Installs RKE2 on downstream (apps) cluster nodes:
- Similar to manager cluster but for agent-only deployment
- Nodes configured as control-plane, etcd, and worker for full functionality
- Kubeconfig management
- Readiness verification

### 5. rancher_downstream_registration Module (NEW)
**Location:** `terraform/modules/rancher_downstream_registration/main.tf`

Registers downstream cluster with Rancher Manager using manifest-based approach:
- Fetches cluster registration manifest from Rancher API
- Applies manifest to all cluster nodes via kubectl
- Manifest includes RBAC, ServiceAccount, Deployment, Secrets
- cattle-cluster-agent pods automatically register cluster

**Why this approach (vs. system-agent-install.sh)?**
- ✅ Manifest-based: Self-contained YAML, no external script downloads
- ✅ Reliable: Uses public /v3/import/{token} endpoint
- ✅ Simple: Just `kubectl apply -f manifest.yaml`
- ✅ No timeouts: Doesn't rely on problematic /v3/connect/agent endpoint
- ✅ Works everywhere: Works on networks with strict egress controls

**Key Features:**
- Automatic token creation/retrieval
- Manifest URL construction with token
- Multi-node deployment via SSH
- Proper error handling and logging

## Deployment Workflow

```
terraform apply
├── 1. Create VMs (10-15 min)
│   ├── Proxmox VM provisioning
│   ├── Cloud-init networking setup
│   └── SSH connectivity verification
├── 2. Install RKE2 on Manager (5-10 min)
│   ├── Install RKE2 on first server
│   ├── Join additional servers
│   ├── Retrieve kubeconfig
│   └── Store locally in ~/.kube/rancher-manager.yaml
├── 3. Deploy Rancher on Manager (5-10 min)
│   ├── Install cert-manager
│   ├── Deploy Rancher Helm chart
│   ├── Create API token via Rancher API
│   ├── Persist token to ~/.kube/.rancher-api-token
│   └── Configure bootstrap password & Ingress
├── 4. Extract Downstream Cluster ID (AUTOMATIC) (<1 min)
│   ├── Call Rancher API to list clusters
│   ├── Extract cluster ID from response (e.g., c-7c2vb)
│   ├── Save to ~/.kube/.downstream-cluster-id
│   └── **Zero manual steps required - fully automated**
├── 5. Register Downstream Cluster (MANIFEST-BASED) (2-3 min)
│   ├── Fetch registration manifest from Rancher API
│   ├── Apply manifest to all downstream nodes via kubectl
│   ├── Create cattle-cluster-agent Deployment
│   └── Pods automatically register with Rancher Manager
└── 6. Install RKE2 on Apps Cluster (5-10 min)
    ├── Install RKE2 on first node
    ├── Join additional nodes
    ├── System-agent auto-registers with Rancher
    └── Retrieve kubeconfig to ~/.kube/nprd-apps.yaml

**Total Time: 30-50 minutes (fully automated, no manual steps)**
```

## Cluster Creation & ID Extraction (NEW - Jan 4, 2026)

### Workflow

**Sequence:**
1. **Create cluster object** in Rancher via API: `POST /v3/clusters`
2. Rancher generates the cluster ID (e.g., `c-7c2vb`)
3. **Extract cluster ID** via API: `GET /v3/clusters`
4. **Register downstream nodes** using the ID

This solves the circular dependency: to register nodes, we need the cluster ID, which is only generated when Rancher creates the cluster object.

### Terraform Implementation

**Step 1: Create cluster object**
```hcl
resource "null_resource" "create_downstream_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      API_TOKEN=$(cat ~/.kube/.rancher-api-token)
      
      # Create cluster object - Rancher generates the ID
      curl -sk -X POST \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"nprd-apps","description":"Non-production applications cluster"}' \
        "https://rancher.example.com/v3/clusters"
    EOT
  }
}
```

**Step 2: Extract cluster ID**
```hcl
resource "null_resource" "fetch_downstream_cluster_id" {
  provisioner "local-exec" {
    command = <<-EOT
      API_TOKEN=$(cat ~/.kube/.rancher-api-token)
      
      # Get cluster ID from response
      CLUSTER_ID=$(curl -sk \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "https://rancher.example.com/v3/clusters" \
        | grep -B 5 '"name":"nprd-apps"' | grep -o '"id":"[^"]*' | tail -1)
      
      echo "${CLUSTER_ID}" > ~/.kube/.downstream-cluster-id
    EOT
  }
  depends_on = [null_resource.create_downstream_cluster]
}
```

**Step 3: Register cluster using extracted ID**
```hcl
module "rancher_downstream_registration" {
  cluster_id = trimspace(data.local_file.downstream_cluster_id[0].content)
}
```

### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/v3/clusters` | Create cluster object |
| GET | `/v3/clusters` | List all clusters (get IDs) |
| GET | `/v3/import/{token}_{cluster-id}.yaml` | Get registration manifest |

## Cluster ID Extraction (DEPRECATED)

### Problem Solved

**Before**: Cluster ID was hardcoded in Terraform
```hcl
cluster_id = "c-7c2vb"  # ❌ Hardcoded, breaks on different clusters
```

**Now**: Cluster ID is dynamically extracted from Rancher API
```hcl
cluster_id = trimspace(data.local_file.downstream_cluster_id[0].content)  # ✅ Automatic
```

### How It Works

1. **Rancher Manager creates cluster** during `module.rancher_deployment`
2. **Terraform fetches cluster list** from Rancher API (`GET /v3/clusters`)
3. **Cluster ID extracted** from API response (typically second cluster = downstream apps cluster)
4. **Saved to file**: `~/.kube/.downstream-cluster-id`
5. **Used automatically** by `rancher_downstream_registration` module

### Terraform Implementation

```hcl
# 1. Call Rancher API to fetch cluster ID
resource "null_resource" "fetch_downstream_cluster_id" {
  count = var.register_downstream_cluster ? 1 : 0
  
  provisioner "local-exec" {
    command = <<-EOT
      # Read API token from file (created by deploy-rancher.sh)
      API_TOKEN=$(cat "~/.kube/.rancher-api-token")
      
      # Query Rancher API for clusters
      CLUSTER_ID=$(curl -sk \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "https://rancher.example.com/v3/clusters" \
        | grep -o '"id":"[^"]*' | sed 's/"//g' | head -2 | tail -1)
      
      # Save cluster ID to file
      echo "${CLUSTER_ID}" > "~/.kube/.downstream-cluster-id"
    EOT
  }
}

# 2. Read cluster ID from file
data "local_file" "downstream_cluster_id" {
  count    = var.register_downstream_cluster ? 1 : 0
  filename = "~/.kube/.downstream-cluster-id"
  depends_on = [null_resource.fetch_downstream_cluster_id]
}

# 3. Use extracted ID in registration module
module "rancher_downstream_registration" {
  cluster_id = trimspace(data.local_file.downstream_cluster_id[0].content)
}
```

### API Endpoint Used

```bash
# Endpoint
GET https://rancher.example.com/v3/clusters

# Headers
Authorization: Bearer <token-from-rancher-api-token-file>

# Response (sample)
{
  "data": [
    {
      "id": "local",
      "name": "local",
      "kind": "Cluster",
      ...
    },
    {
      "id": "c-7c2vb",           # ← EXTRACTED HERE
      "name": "nprd-apps",
      "kind": "Cluster",
      ...
    }
  ]
}
```

### Troubleshooting

**Issue**: `ERROR: Could not fetch downstream cluster ID from Rancher API`

**Solutions**:
1. Verify Rancher Manager is running:
   ```bash
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get pods -n cattle-system | grep rancher
   ```

2. Verify API token file exists and is readable:
   ```bash
   cat ~/.kube/.rancher-api-token
   # Should print token starting with "token-"
   ```

3. Verify Rancher API is accessible:
   ```bash
   API_TOKEN=$(cat ~/.kube/.rancher-api-token)
   curl -sk -H "Authorization: Bearer ${API_TOKEN}" \
     https://rancher.example.com/v3/clusters | jq '.data[] | {id, name}'
   ```

4. Verify downstream cluster exists:
   ```bash
   # Should see at least 2 clusters: "local" (manager) and "c-XXXXX" (apps)
   ```

## Updated main.tf

The main Terraform file orchestrates the deployment:

```hcl
# 1. Provision VMs
module "rancher_manager_primary" { ... }
module "rancher_manager_additional" { ... }
module "nprd_apps_primary" { ... }
module "nprd_apps_additional" { ... }

# 2. Install RKE2 on Manager
module "rke2_manager" { ... }

# 3. Deploy Rancher (creates API token)
module "rancher_deployment" { ... }

# 4. Create Downstream Cluster Object in Rancher (AUTOMATIC)
resource "null_resource" "create_downstream_cluster" { ... }

# 5. Extract Downstream Cluster ID (AUTOMATIC)
resource "null_resource" "fetch_downstream_cluster_id" { ... }
data "local_file" "downstream_cluster_id" { ... }

# 6. Register Downstream Cluster (MANIFEST-BASED)
module "rancher_downstream_registration" { ... }

# 7. Install RKE2 on Apps Cluster
module "rke2_apps" { ... }
```

## Deployment Workflow

```
terraform apply
├── 1. Create VMs (10-15 min)
│   ├── Proxmox VM provisioning
│   ├── Cloud-init networking setup
│   └── SSH connectivity verification
├── 2. Install RKE2 on Manager (5-10 min)
│   ├── Install RKE2 on first server
│   ├── Join additional servers
│   ├── Retrieve kubeconfig
│   └── Store locally in ~/.kube/rancher-manager.yaml
├── 3. Deploy Rancher on Manager (5-10 min)
│   ├── Install cert-manager
│   ├── Deploy Rancher Helm chart
│   ├── Create API token via Rancher API
│   ├── Persist token to ~/.kube/.rancher-api-token
│   └── Configure bootstrap password & Ingress
├── 4. Register Downstream Cluster (NATIVE) (2-3 min)
│   ├── Use rancher2 provider with API token
│   ├── Create cluster object in Rancher
│   ├── Extract registration credentials
│   └── Pass to downstream cluster VMs
└── 5. Install RKE2 on Apps Cluster (5-10 min)
    ├── Install RKE2 on first node
    ├── Join additional nodes
    ├── System-agent auto-registers with Rancher
    └── Retrieve kubeconfig to ~/.kube/nprd-apps.yaml

Total Time: 30-50 minutes (fully automated, no manual steps)
```

**Key Improvements (Native rancher2 Provider):**
- ✅ **Zero manual token copy/paste** - API token auto-created
- ✅ **Single terraform apply** - Everything deploys end-to-end
- ✅ **No Rancher UI steps** - Automatic cluster registration
- ✅ **CI/CD friendly** - No interactive configuration required
- ✅ **Self-healing** - Token automatically refreshed if needed

## Configuration Required

Update `terraform/terraform.tfvars`:

```hcl
# Existing (Proxmox)
proxmox_api_url = "https://pve.example.com:8006/api2/json"
proxmox_api_user = "root@pam"
proxmox_api_token_id = "terraform"
proxmox_api_token_secret = "xxx-xxx-xxx"
proxmox_node = "pve"

# Existing (Clusters)
clusters = {
  manager = {
    node_count = 3
    # ... other settings
  }
  nprd-apps = {
    node_count = 3
    # ... other settings
  }
}

# NEW (Rancher)
rancher_version = "v2.7.7"
rancher_password = "your-secure-bootstrap-password"
rancher_hostname = "rancher.example.com"

# Existing (SSH)
ssh_private_key = "../.keys/id_rsa"  # public key from "${ssh_private_key}.pub"
```

## Deployment Steps

```bash
# 1. Initialize Terraform
cd /home/lee/git/rancher-deploy/terraform
terraform init

# 2. Preview changes
terraform plan

# 3. Deploy everything
terraform apply

# 4. Monitor progress
# Watch the logs in another terminal:
terraform apply -input=false 2>&1 | tail -f

# 5. Access Rancher
terraform output rancher_url
# Username: admin
# Password: <from rancher_password>
```

## Outputs

After successful deployment:

```bash
terraform output

# Returns:
# cluster_ips = {
#   "manager"   = ["192.168.1.100", "192.168.1.101", "192.168.1.102"]
#   "nprd_apps" = ["192.168.1.110", "192.168.1.111", "192.168.1.112"]
# }
# kubeconfig_paths = {
#   "manager"   = "~/.kube/rancher-manager.yaml"
#   "nprd_apps" = "~/.kube/nprd-apps.yaml"
# }
# rancher_url = "https://rancher.example.com"
```

## Using kubeconfig

```bash
# Manager cluster
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get nodes
kubectl get pods -n cattle-system

# Apps cluster
export KUBECONFIG=~/.kube/nprd-apps.yaml
kubectl get nodes
```

## Customization Options

### Change RKE2 Version
Edit `main.tf`:
```hcl
module "rke2_manager" {
  rke2_version = "v1.27.5"
}
```

### Change Rancher Version
Edit `terraform.tfvars`:
```hcl
rancher_version = "v2.8.0"
```

### Customize Rancher Ingress
Edit `modules/rancher_cluster/main.tf`:
```hcl
set {
  name  = "ingress.class"
  value = "traefik"  # or "nginx", etc
}
```

### Add More Nodes
Edit `terraform.tfvars`:
```hcl
clusters = {
  manager = {
    node_count = 5  # More nodes for HA
  }
}
```

## Troubleshooting

### SSH Connection Fails
```bash
# Verify SSH key
ssh -i .keys/id_rsa ubuntu@192.168.1.100

# Check if cloud-init is complete
cloud-init status
```

### RKE2 Installation Hangs
```bash
# Check logs on VM
ssh ubuntu@192.168.1.100
sudo journalctl -u rke2-server -f
```

### Kubernetes Nodes Not Ready
```bash
# Check node status
kubectl get nodes -o wide

# Check logs
kubectl describe node <node-name>
```

### Rancher Pod Stuck in Pending
```bash
# Check cert-manager
kubectl get pods -n cert-manager

# Check Rancher logs
kubectl logs -n cattle-system -l app=rancher --tail=100
```

## Next Steps

After Rancher is deployed and downstream cluster is automatically registered:

1. **Access Rancher UI**
   ```
   https://rancher.example.com
   Username: admin
   Password: <from tfvars>
   ```

2. **Change admin password** in Rancher UI (important!)

3. **Verify Downstream Cluster Registration**
   ```bash
   # In Rancher UI: Cluster Management
   # nprd-apps should appear with all 3 nodes healthy
   
   # Or via kubectl:
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get clusters.management.cattle.io
   kubectl describe clusters.management.cattle.io nprd-apps
   ```

4. **Configure authentication** - LDAP, OIDC, GitHub, etc.

5. **Deploy applications** - Use Rancher to manage workloads

6. **Set up monitoring** - Prometheus, Grafana, etc.

## Module Dependencies

```
proxmox_vm (VMs)
    ↓
rke2_cluster (RKE2 Installation)
    ↓
rancher_cluster (Rancher Deployment)
```

All dependencies are configured in `main.tf` with `depends_on` blocks to ensure proper ordering.

## Testing the Setup

### Pre-Deployment
```bash
terraform plan -out=tfplan
terraform show tfplan
```

### During Deployment
```bash
# Monitor Terraform output
terraform apply 2>&1 | grep -E "^module\.|^aws_|^kubernetes_|^helm_"
```

### Post-Deployment
```bash
# Verify all nodes
kubectl get nodes

# Verify Rancher
kubectl get helmrelease -n cattle-system
kubectl get pods -n cattle-system

# Verify DNS/Ingress
kubectl get ingress -n cattle-system
curl -k https://rancher.example.com/health
```

## Security Notes

- **API Token**: Stored in tfvars (add to .gitignore!)
- **SSH Key**: Referenced via `ssh_private_key` (repo convention `.keys/`; ensure 600 permissions)
- **Rancher Password**: Defined in tfvars (change in UI immediately after login)
- **Ingress TLS**: Automatically provisioned with Let's Encrypt

## Performance Tuning

### For larger deployments:
```hcl
# Increase resources in terraform.tfvars
clusters = {
  manager = {
    cpu_cores  = 8      # from 4
    memory_mb  = 16384  # from 8192
    disk_size_gb = 200  # from 50
  }
}
```

### For faster deployments:
```bash
# Use newer RKE2 version
# Increase worker node count
# Pre-warm image (multiple deployments)
```

## Cleanup

To destroy everything:

```bash
# Destroy Rancher and RKE2
terraform destroy

# Confirm all VMs are gone
pvesh get /nodes/pve/qemu
```

## References

- [bpg/proxmox Provider](https://github.com/bpg/terraform-provider-proxmox)
- [RKE2 Documentation](https://docs.rke2.io/)
- [Rancher Documentation](https://rancher.com/docs/)
- [Kubernetes Provider](https://registry.terraform.io/providers/hashicorp/kubernetes)
- [Helm Provider](https://registry.terraform.io/providers/hashicorp/helm)
