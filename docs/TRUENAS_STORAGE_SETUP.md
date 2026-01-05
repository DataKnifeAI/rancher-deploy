# TrueNAS Storage Setup with Democratic CSI

Complete guide for setting up TrueNAS NFS storage with democratic-csi in your RKE2/Rancher cluster.

## Overview

This guide covers:
- TrueNAS configuration and API key setup
- Democratic CSI installation (automated via Terraform or manual)
- Storage class configuration
- Secrets management
- Troubleshooting

## Architecture

```
TrueNAS Server
    ↓ NFS
Kubernetes Cluster
    ↓ democratic-csi driver
PersistentVolumeClaims
```

## Quick Start

### Automated Installation (Recommended)

Democratic CSI is **automatically deployed** at the end of your Terraform plan if TrueNAS is configured:

1. **Configure TrueNAS in Terraform** (`terraform/terraform.tfvars`):
   ```hcl
   truenas_host = "truenas.example.com"
   truenas_api_key = "your-api-key-here"
   truenas_dataset = "/mnt/pool/dataset"
   truenas_user = "csi-user"
   csi_storage_class_name = "truenas-nfs"
   csi_storage_class_default = true
   ```

2. **Run Terraform**:
   ```bash
   cd terraform
   terraform apply
   ```

   The storage class will be created automatically at the end of the deployment.

### Manual Installation

If you prefer manual installation or need to install after Terraform:

1. **Generate Helm values**:
   ```bash
   ./scripts/generate-helm-values-from-tfvars.sh
   ```

2. **Install via script**:
   ```bash
   export KUBECONFIG=~/.kube/your-cluster.yaml
   ./scripts/install-democratic-csi.sh
   ```

3. **Or install via Helm**:
   ```bash
   helm repo add democratic-csi https://democratic-csi.github.io/charts/
   helm repo update
   helm install democratic-csi democratic-csi/democratic-csi \
     --namespace democratic-csi \
     --create-namespace \
     -f helm-values/democratic-csi-truenas.yaml
   ```

## TrueNAS Configuration

### 1. Create API Key

1. Login to TrueNAS UI: `https://your-truenas-host`
2. Navigate: **System → API Keys → Add**
3. Name: `rke2-csi` (or your preferred name)
4. Generate key and **copy it immediately** (you won't see it again)
5. Add to `terraform/terraform.tfvars`:
   ```hcl
   truenas_api_key = "1-xxxxxxxxxxxxx"
   ```

### 2. Configure NFS Share

Ensure NFS share is configured on TrueNAS:

- **Path**: `/mnt/pool/dataset` (your dataset path)
- **Network**: `10.0.0.0/24` (your cluster subnet)
- **Authorized Networks**: `10.0.0.0/24` (your cluster subnet)
- **Maproot User**: `root` (or user with dataset ownership)
- **Maproot Group**: `wheel`

### 3. User Permissions

The TrueNAS user needs:

- **File System Ownership**: User must own the dataset
- **API Access**: API key with read/write permissions
- **No Special Groups/Roles**: File system ownership is sufficient

**Setting Ownership**:
```bash
# SSH to TrueNAS
ssh admin@your-truenas-host

# Set ownership
sudo chown -R csi-user:csi-user /mnt/pool/dataset
```

## Secrets Management

### Architecture

```
terraform/terraform.tfvars (source of truth)
    ↓
scripts/generate-helm-values-from-tfvars.sh
    ↓
helm-values/democratic-csi-truenas.yaml (generated)
    ↓
Helm installation uses generated values
```

### Workflow

1. **Edit secrets** in `terraform/terraform.tfvars`
2. **Generate Helm values**: `./scripts/generate-helm-values-from-tfvars.sh`
3. **Install/Update**: Terraform will deploy automatically, or run Helm manually

### Security

- ✅ `terraform/terraform.tfvars` - gitignored (contains secrets)
- ✅ `helm-values/democratic-csi-truenas.yaml` - gitignored (auto-generated)
- ✅ Example files tracked in git (no secrets)

## Storage Class Configuration

### Default Storage Class

The storage class is configured as **default** by default. Only one default storage class is allowed per cluster.

**If another storage class is already default**:
```bash
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Find current default
kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'

# Remove default from existing
kubectl patch storageclass <existing-sc> -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'

# Set truenas-nfs as default
kubectl patch storageclass truenas-nfs -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

### Storage Class Parameters

- **Name**: `truenas-nfs` (configurable)
- **Provisioner**: `org.democratic-csi.truenas-nfs`
- **Reclaim Policy**: `Delete`
- **Volume Binding**: `Immediate`
- **Volume Expansion**: Enabled
- **NFS Version**: 4

## Verification

### Check Installation

```bash
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Check pods
kubectl get pods -n democratic-csi

# Check storage class
kubectl get storageclass truenas-nfs

# Check CSI driver
kubectl get csidriver
```

### Test PVC Creation

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: truenas-nfs
  resources:
    requests:
      storage: 10Gi
EOF

# Check status
kubectl get pvc test-pvc
kubectl describe pvc test-pvc
```

## Troubleshooting

### PVC Stuck in Pending

```bash
# Check events
kubectl describe pvc <pvc-name>
kubectl get events --sort-by='.lastTimestamp' | grep <pvc-name>

# Check controller logs
kubectl logs -n democratic-csi -l app=democratic-csi-controller
```

### TrueNAS Connectivity Issues

```bash
# Test from pod
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
# Inside pod:
ping your-truenas-host
```

### API Key Issues

```bash
# Test API access
API_KEY="your-api-key"
TRUENAS_HOST="your-truenas-host"
DATASET_PATH="pool%2Fdataset"  # URL-encoded dataset path
curl -k -H "Authorization: Bearer ${API_KEY}" \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset/id/${DATASET_PATH}"
```

### Check Pod Logs

```bash
# Controller logs
kubectl logs -n democratic-csi -l app=democratic-csi-controller

# Node logs
kubectl logs -n democratic-csi -l app=democratic-csi-node
```

### Verify NFS on Nodes

```bash
# SSH to each node
ssh ubuntu@nprd-apps-1

# Install NFS client (if needed)
sudo apt-get install -y nfs-common

# Test mount
sudo mount -t nfs4 your-truenas-host:/mnt/pool/dataset /mnt/test
sudo umount /mnt/test
```

## Terraform Integration

### Automatic Deployment

When TrueNAS is configured in `terraform.tfvars`, Terraform will:

1. Generate Helm values from Terraform variables
2. Install democratic-csi at the end of the plan
3. Create and configure the storage class
4. Set it as default (if configured)

### Resource Dependencies

```
VMs → RKE2 Clusters → Rancher → Downstream Registration → Kubeconfigs → Democratic CSI
```

The democratic-csi resource depends on:
- `null_resource.merge_kubeconfigs` (kubeconfigs ready)
- `module.rke2_apps` (apps cluster ready)

### Updating Configuration

To update TrueNAS configuration:

1. Edit `terraform/terraform.tfvars`
2. Run `terraform apply`
3. Terraform will regenerate Helm values and update the deployment

## Common Commands

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Check CSI status
kubectl get pods -n democratic-csi
kubectl get storageclass
kubectl get csidriver

# View logs
kubectl logs -n democratic-csi -l app=democratic-csi-controller
kubectl logs -n democratic-csi -l app=democratic-csi-node

# List PVCs
kubectl get pvc --all-namespaces

# Delete test PVC
kubectl delete pvc test-pvc
```

## Related Documentation

- **[TRUENAS_SECRETS_MANAGEMENT.md](TRUENAS_SECRETS_MANAGEMENT.md)** - Detailed secrets management workflow
- **[STORAGE_CLASS_DEFAULT.md](STORAGE_CLASS_DEFAULT.md)** - Storage class default configuration
- **[DEMOCRATIC_CSI_TRUENAS_SETUP.md](DEMOCRATIC_CSI_TRUENAS_SETUP.md)** - General democratic-csi setup guide
