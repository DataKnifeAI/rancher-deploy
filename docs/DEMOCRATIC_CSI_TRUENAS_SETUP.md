# Democratic CSI with TrueNAS and Rancher Setup Guide

## Overview

Democratic CSI is a unified Container Storage Interface (CSI) driver that supports multiple storage backends, including TrueNAS (both SCALE and CORE). This guide covers setting up democratic-csi with TrueNAS in your Rancher-managed RKE2 clusters.

## Prerequisites

### TrueNAS Requirements
- TrueNAS SCALE or TrueNAS CORE running and accessible
- NFS or iSCSI service enabled on TrueNAS
- A dataset/pool configured for Kubernetes storage
- User credentials with appropriate permissions
- Network connectivity from Kubernetes nodes to TrueNAS

### Rancher/RKE2 Requirements
- RKE2 cluster managed by Rancher
- `kubectl` access to the cluster
- Helm 3.x installed (for installation)
- Sufficient permissions to create namespaces, service accounts, and cluster roles

## Architecture

```
RKE2 Cluster
├── Democratic CSI Driver
│   ├── Controller Pod (manages volumes)
│   └── Node Pods (one per worker node)
├── Storage Classes
│   ├── NFS Storage Class
│   └── iSCSI Storage Class (optional)
└── TrueNAS Backend
    ├── NFS Shares
    └── iSCSI Targets
```

## Step 1: Prepare TrueNAS

### 1.1 Create Dataset for Kubernetes

1. **Log into TrueNAS Web UI**
2. **Create a dataset:**
   - Storage → Pools → Add Dataset
   - Name: `k8s-storage` (or your preferred name, e.g., `RKE2`)
   - Type: Filesystem
   - Share Type: Generic
   - Enable compression (recommended: lz4)
   - Enable deduplication (optional, requires more RAM)

### 1.2 Configure User Permissions

The TrueNAS user needs specific permissions to create and manage datasets via the API.

#### Minimum Required Permissions

**Quick Answer:**
- User with **write access** to dataset
- Ability to **create and delete** child datasets
- **API key** for that user
- **Network access** to TrueNAS API (port 443)

#### Detailed Requirements

**1. Dataset Permissions**

The user needs to be able to:
- ✅ **Create** datasets under parent dataset (for PVCs)
- ✅ **Delete** datasets under parent dataset (when PVCs are deleted)
- ✅ **Read** dataset properties
- ✅ **Modify** dataset properties (optional, for quotas/compression)

**How to Grant:**
```bash
# Option 1: Ownership (simplest and recommended)
ssh root@your-truenas-host
chown -R csi-user:csi-user /mnt/pool/dataset

# Option 2: ACLs (more flexible, TrueNAS SCALE)
setfacl -R -m u:csi-user:rwx /mnt/pool/dataset
setfacl -R -d -m u:csi-user:rwx /mnt/pool/dataset
```

**2. Verify Permissions**

Test if the user can create and delete datasets:
```bash
# SSH to TrueNAS
ssh root@your-truenas-host

# Test if user can create datasets
sudo -u csi-user zfs create pool/dataset/test-permission-check
sudo -u csi-user zfs destroy pool/dataset/test-permission-check

# If successful: ✅ User has sufficient permissions
# If fails: Grant permissions using chown or ACLs as shown above
```

**3. Permission Levels Comparison**

| Level | Permissions | Limitations | Use Case |
|-------|-------------|-------------|----------|
| **Level 1: Minimum** | Dataset access only | Cannot create NFS shares via API | Basic functionality, manual NFS management |
| **Level 2: Recommended** | Dataset + NFS management | May require admin/root-level access | Full automated functionality |
| **Level 3: Production** | Dedicated user with minimal permissions | Requires careful setup | Production environments (best practice) |

**Recommended for Production:** Use Level 3 - dedicated user with ownership of dataset only.

#### API Access

The user needs:
- ✅ **API key** created in TrueNAS (System → API Keys)
- ✅ **HTTPS access** to TrueNAS API (port 443)
- ✅ **Network connectivity** from RKE2 nodes to TrueNAS

**API Endpoints Used:**
- `POST /api/v2.0/pool/dataset` - Create datasets
- `DELETE /api/v2.0/pool/dataset/id/{id}` - Delete datasets
- `GET /api/v2.0/pool/dataset/id/{id}` - Read dataset info
- `GET /api/v2.0/pool/dataset` - List datasets

**Note:** API keys inherit the user's permissions, so if the user can create datasets, the API key will work.

### 1.3 Create API Key

1. **Login to TrueNAS UI**: `https://your-truenas-host`
2. **Navigate**: **System → API Keys → Add**
3. **User**: Select the user with dataset permissions (e.g., `csi-user` or `rke2`)
4. **Name**: `k8s-csi` (or your preferred name)
5. **Generate key** and **copy it immediately** (you won't see it again)
6. **Add to Terraform variables**:
   ```hcl
   # terraform/terraform.tfvars
   truenas_api_key = "1-xxxxxxxxxxxxx"
   ```

**Important Notes:**
- Use the IP address that NFS service is bound to (not just any IP)
- Verify NFS service binding: Services → NFS → Edit → Check "Bind IP Addresses"
- API Port: `443` (HTTPS) or `80` (HTTP)

**Test API Access:**
```bash
API_KEY="your-api-key"
TRUENAS_HOST="your-truenas-host"

# Test dataset query
curl -k -H "Authorization: Bearer ${API_KEY}" \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset/id/SAS%2FRKE2"

# Test dataset creation
curl -k -X POST \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "SAS/RKE2/test-api", "type": "FILESYSTEM"}' \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset"

# Clean up test dataset
curl -k -X DELETE \
  -H "Authorization: Bearer ${API_KEY}" \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset/id/SAS%2FRKE2%2Ftest-api"
```

### 1.4 Configure NFS Share

1. **Enable NFS Service:**
   - Services → NFS → Enable
   - **Important:** Check "Bind IP Addresses" configuration
   - Ensure NFS service is bound to the IP address you'll use in CSI configuration
   - If using multiple IPs, bind to all required IPs or use `0.0.0.0` for all interfaces

2. **Create NFS Share:**
   - Sharing → Unix Shares (NFS) → Add
   - Path: `/mnt/<pool>/k8s-storage` (or your dataset path)
   - Description: `Kubernetes Storage`
   - Enable: ✓
   - Network: `10.0.0.0/24` (your cluster subnet, e.g., `192.168.14.0/24`)
   - Authorized Networks: `10.0.0.0/24` (your cluster subnet)
   - Maproot User: `root` (or user with dataset ownership)
   - Maproot Group: `wheel`
   - Save

3. **Verify NFS Service Binding:**
   - **Critical:** Test NFS connectivity from a cluster node before configuring CSI
   ```bash
   # From a cluster node, test NFS port accessibility:
   timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.9.10/2049' && echo 'Port 2049 accessible' || echo 'Port 2049 NOT accessible'
   
   # Test manual mount with default options:
   sudo mkdir -p /tmp/test-nfs
   sudo mount -t nfs 192.168.9.10:/mnt/pool/k8s-storage /tmp/test-nfs
   ls -la /tmp/test-nfs
   sudo umount /tmp/test-nfs
   sudo rmdir /tmp/test-nfs
   ```
   
   **If mount fails with "Connection refused":**
   - NFS service may not be bound to that IP address
   - Check TrueNAS NFS service configuration
   - Update bind IP addresses or use correct IP in CSI configuration

## Step 2: Install Democratic CSI

### 2.1 Automated Installation via Terraform (Recommended)

Democratic CSI is **automatically deployed** at the end of your Terraform plan if TrueNAS is configured:

1. **Configure TrueNAS in Terraform** (`terraform/terraform.tfvars`):
   ```hcl
   truenas_host = "192.168.9.10"
   truenas_api_key = "your-api-key-here"
   truenas_dataset = "/mnt/SAS/RKE2"
   truenas_user = "rke2"
   truenas_protocol = "https"
   truenas_port = 443
   truenas_allow_insecure = true
   csi_storage_class_name = "truenas-nfs"
   csi_storage_class_default = true
   ```

2. **Generate Helm values from Terraform variables**:
   ```bash
   ./scripts/generate-helm-values-from-tfvars.sh
   ```

3. **Run Terraform**:
   ```bash
   cd terraform
   terraform apply
   ```

   The storage class will be created automatically at the end of the deployment.

**Resource Dependencies:**
```
VMs → RKE2 Clusters → Rancher → Downstream Registration → Kubeconfigs → Democratic CSI
```

The democratic-csi resource depends on:
- `null_resource.merge_kubeconfigs` (kubeconfigs ready)
- `module.rke2_apps` (apps cluster ready)

### 2.2 Secrets Management

#### Architecture

```
terraform/terraform.tfvars (source of truth)
    ↓
scripts/generate-helm-values-from-tfvars.sh
    ↓
helm-values/democratic-csi-truenas.yaml (generated)
    ↓
Helm installation uses generated values
```

#### Workflow

1. **Edit secrets** in `terraform/terraform.tfvars`
2. **Generate Helm values**: `./scripts/generate-helm-values-from-tfvars.sh`
3. **Install/Update**: Terraform will deploy automatically, or run Helm manually

#### Security

- ✅ `terraform/terraform.tfvars` - gitignored (contains secrets)
- ✅ `helm-values/democratic-csi-truenas.yaml` - gitignored (auto-generated)
- ✅ Example files tracked in git (no secrets)

#### Terraform Variables

All TrueNAS variables are defined in `terraform/variables.tf`:

- `truenas_host` - TrueNAS hostname
- `truenas_api_key` - API key (sensitive)
- `truenas_dataset` - Dataset path
- `truenas_user` - Username
- `truenas_protocol` - Protocol (https/http)
- `truenas_port` - API port
- `truenas_allow_insecure` - Allow self-signed certs
- `csi_storage_class_name` - Storage class name
- `csi_storage_class_default` - Make it default

#### Updating Configuration

To update TrueNAS configuration:

1. Edit `terraform/terraform.tfvars`
2. Run `./scripts/generate-helm-values-from-tfvars.sh` to regenerate Helm values
3. Run `terraform apply` (if using Terraform) or reinstall via Helm

**Note:** The Helm values file is **auto-generated** from `terraform.tfvars`. Do not edit it manually - it will be overwritten.

### 2.3 Manual Installation via Rancher UI

If you prefer manual installation or need to install after Terraform:

1. **Navigate to Cluster:**
   - Cluster Management → nprd-apps → Explore Cluster

2. **Install via Apps & Marketplace:**
   - Apps & Marketplace → Charts
   - Search for: `democratic-csi`
   - Click: `democratic-csi` (from `democratic-csi` repository)
   - Click: Install

3. **Configure Installation:**
   - Namespace: `democratic-csi` (create new)
   - Release Name: `democratic-csi`
   - Version: Latest stable (e.g., `v1.1.0`)

4. **Configure Values:**

1. **Navigate to Cluster:**
   - Cluster Management → nprd-apps → Explore Cluster

2. **Install via Apps & Marketplace:**
   - Apps & Marketplace → Charts
   - Search for: `democratic-csi`
   - Click: `democratic-csi` (from `democratic-csi` repository)
   - Click: Install

3. **Configure Installation:**
   - Namespace: `democratic-csi` (create new)
   - Release Name: `democratic-csi`
   - Version: Latest stable (e.g., `v1.1.0`)

4. **Configure Values:**

```yaml
# CSI Driver Configuration (required by chart)
csiDriver:
  name: truenas-nfs  # Must be unique per cluster
  enabled: true
  attachRequired: true
  podInfoOnMount: true

# Driver Configuration
driver:
  config:
    driver: freenas-api-nfs  # Use freenas-api-nfs for TrueNAS API-based NFS
    # HTTP connection to TrueNAS API
    httpConnection:
      protocol: "https"  # or "http"
      host: "truenas.example.com"  # Your TrueNAS hostname/IP
      port: 443  # or 80 for HTTP
      apiKey: "your-api-key-here"  # From Step 1.3
      allowInsecure: false  # Set to true if using self-signed cert
    # ZFS dataset configuration
    zfs:
      datasetParentName: "pool/k8s-storage"  # ZFS dataset name (without /mnt/ prefix)
      detachedSnapshotsDatasetParentName: "pool/k8s-storage-snapshots"
      datasetEnableQuotas: true
      datasetEnableReservation: false
      datasetPermissionsMode: "0777"
      datasetPermissionsUser: 0
      datasetPermissionsGroup: 0
    # NFS share configuration
    # IMPORTANT: Use shareHost (not server) for freenas-api-nfs driver
    nfs:
      shareHost: "truenas.example.com"  # NFS server hostname/IP
      shareAlldirs: false
      shareAllowedHosts: []
      shareAllowedNetworks: []
      shareMaprootUser: root
      shareMaprootGroup: root
      shareMapallUser: ""
      shareMapallGroup: ""
    
# Storage Classes
storageClasses:
  - name: truenas-nfs
    default: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: "nfs"
      parentDataset: "pool/k8s-storage"  # ZFS dataset name (without /mnt/ prefix)
      nfsServer: "truenas.example.com"  # NFS server for volume context
      nfsVersion: "4"  # Recommended NFS version
```

5. **Click Install**

### 2.4 Manual Installation via Helm CLI (Alternative)

```bash
# Add democratic-csi Helm repository
helm repo add democratic-csi https://democratic-csi.github.io/charts/
helm repo update

# Set your kubeconfig
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Create namespace
kubectl create namespace democratic-csi

# Install democratic-csi
helm install democratic-csi democratic-csi/democratic-csi \
  --namespace democratic-csi \
  --set csiDriver.name=truenas-nfs \
  --set csiDriver.enabled=true \
  --set driver.config.driver=truenas-nfs \
  --set config.truenas.host=truenas.example.com \
  --set config.truenas.apiKey=your-api-key \
  --set config.truenas.protocol=https \
  --set config.truenas.port=443 \
  --set config.truenas.dataset=/mnt/pool/k8s-storage \
  --set storageClasses[0].name=truenas-nfs \
  --set storageClasses[0].default=true
```

### 2.5 Manual Installation via Script

If you prefer using the installation script:

```bash
# Generate Helm values first
./scripts/generate-helm-values-from-tfvars.sh

# Install via script
export KUBECONFIG=~/.kube/nprd-apps.yaml
./scripts/install-democratic-csi.sh
```

## Step 3: Verify Installation

### 3.1 Check Pods

```bash
kubectl get pods -n democratic-csi
```

Expected output:
```
NAME                                  READY   STATUS    RESTARTS   AGE
democratic-csi-controller-0           2/2     Running   0          2m
democratic-csi-node-xxxxx             2/2     Running   0          2m
democratic-csi-node-yyyyy             2/2     Running   0          2m
democratic-csi-node-zzzzz             2/2     Running   0          2m
```

### 3.2 Check Storage Classes

```bash
kubectl get storageclass
```

Expected output:
```
NAME          PROVISIONER              RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
truenas-nfs   truenas-nfs.csi.k8s.io   Delete          Immediate           true                   2m
```

### 3.3 Check CSI Driver

```bash
kubectl get csidriver
```

Expected output:
```
NAME          ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   TOKENREQUESTS   REQUIRESREPUBLISH   AGE
truenas-nfs   false            false            false             <unset>         false               2m
```

## Step 4: Create Test PVC

### 4.1 Create PVC Manifest

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany  # NFS supports ReadWriteMany
  storageClassName: truenas-nfs
  resources:
    requests:
      storage: 10Gi
```

### 4.2 Apply and Verify

```bash
kubectl apply -f test-pvc.yaml
kubectl get pvc
kubectl describe pvc test-pvc
```

Expected output:
```
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
test-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            truenas-nfs   30s
```

### 4.3 Verify Volume on TrueNAS

1. **Check TrueNAS UI:**
   - Storage → Pools → k8s-storage
   - You should see a new dataset: `pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

2. **Check via API:**
   ```bash
   curl -k -H "Authorization: Bearer YOUR_API_KEY" \
     https://truenas.example.com/api/v2.0/pool/dataset/id/k8s-storage%2Fpvc-xxxxxxxx
   ```

## Step 5: Configure Storage Classes in Rancher

### 5.1 Create Storage Class via Rancher UI

1. **Navigate to Cluster:**
   - Cluster Management → nprd-apps → Storage → Storage Classes

2. **Create Storage Class:**
   - Click: Create
   - Name: `truenas-nfs-fast` (or your preferred name)
   - Provisioner: `truenas-nfs.csi.k8s.io`
   - Reclaim Policy: `Delete`
   - Volume Binding Mode: `Immediate`
   - Allow Volume Expansion: ✓

3. **Add Parameters:**
   ```
   parentDataset: /mnt/pool/k8s-storage
   fsType: nfs
   ```

4. **Set as Default** (optional): ✓

5. **Click Create**

### 5.2 Multiple Storage Classes (Optional)

You can create multiple storage classes for different use cases:

```yaml
# Fast storage (SSD pool)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs-fast
provisioner: truenas-nfs.csi.k8s.io
parameters:
  parentDataset: /mnt/ssd-pool/k8s-storage
  fsType: nfs
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
# Standard storage (HDD pool)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs-standard
provisioner: truenas-nfs.csi.k8s.io
parameters:
  parentDataset: /mnt/hdd-pool/k8s-storage
  fsType: nfs
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

## Step 6: Use Storage in Applications

### 6.1 Example: Deploy Application with PVC

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-with-storage
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        volumeMounts:
        - name: storage
          mountPath: /usr/share/nginx/html
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: test-pvc
```

### 6.2 Example: StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "password"
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: truenas-nfs
      resources:
        requests:
          storage: 20Gi
```

## Step 7: Monitoring and Troubleshooting

### 7.1 Check CSI Driver Logs

```bash
# Controller logs
kubectl logs -n democratic-csi -l app=democratic-csi-controller

# Node logs
kubectl logs -n democratic-csi -l app=democratic-csi-node
```

### 7.2 Common Issues

#### Issue: PVC stuck in Pending

**Symptoms:**
```
kubectl get pvc
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
test-pvc   Pending                                      truenas-nfs    5m
```

**Troubleshooting:**
```bash
# Check PVC events
kubectl describe pvc test-pvc

# Check CSI driver pods
kubectl get pods -n democratic-csi

# Check storage class
kubectl get storageclass truenas-nfs -o yaml

# Verify TrueNAS connectivity from nodes
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
# Inside pod:
ping truenas.example.com
```

#### Issue: Volume Creation Fails

**Check:**
1. TrueNAS API key is valid
2. Dataset path exists on TrueNAS
3. Network connectivity from nodes to TrueNAS
4. NFS service is enabled on TrueNAS
5. Firewall rules allow NFS traffic (port 2049)

#### Issue: Mount Failures

**Check:**
1. NFS client tools installed on nodes:
   ```bash
   # On each RKE2 node
   sudo apt-get install -y nfs-common
   ```

2. NFS share permissions on TrueNAS
3. Network connectivity (ports 111, 2049)

#### Issue: Permission Denied When Creating PVC

**Symptom**: PVC creation fails with "Permission denied" errors

**Check:**
```bash
# Verify user can create datasets
ssh root@your-truenas-host
sudo -u csi-user zfs create pool/dataset/test-permission

# Check dataset ownership
ls -ld /mnt/SAS/RKE2

# Check ACLs (TrueNAS SCALE)
getfacl /mnt/SAS/RKE2
```

**Fix:**
```bash
# Grant ownership
chown -R csi-user:csi-user /mnt/pool/dataset

# Or use ACLs (TrueNAS SCALE)
setfacl -R -m u:csi-user:rwx /mnt/pool/dataset
setfacl -R -d -m u:csi-user:rwx /mnt/pool/dataset
```

#### Issue: API Authentication Failed

**Symptom**: Controller logs show API authentication errors

**Check:**
- API key is correct
- User account is active
- API key hasn't expired
- Network connectivity to TrueNAS

**Fix:**
- Create new API key in TrueNAS UI
- Verify user permissions
- Test API access with curl (see Step 1.3)
- Update `terraform.tfvars` and regenerate Helm values

#### Issue: CSI Node Pods Not Scheduling on Server Nodes

**Symptom**: CSI node pods only on worker nodes, PVCs fail to mount on server nodes

**Root Cause:**
RKE2 server nodes have taints that prevent normal pods from scheduling:
- `node-role.kubernetes.io/control-plane:NoSchedule`
- `node-role.kubernetes.io/etcd:NoExecute`
- `CriticalAddonsOnly`

**Solution:**
Add tolerations to CSI node daemonset (already included in Helm values):
```yaml
# helm-values/democratic-csi-truenas.yaml
node:
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/etcd
      operator: Exists
      effect: NoExecute
    - key: CriticalAddonsOnly
      operator: Exists
```

This ensures CSI node pods can run on server nodes to handle volume mounts for pods scheduled there.

### 7.3 Enable Debug Logging

Update democratic-csi values:

```yaml
driver:
  config:
    driver: freenas-api-nfs
    logLevel: debug
```

Or via Helm:

```bash
helm upgrade democratic-csi democratic-csi/democratic-csi \
  --namespace democratic-csi \
  --set driver.config.logLevel=debug
```

## Step 8: Production Considerations

### 8.1 Security

1. **Use HTTPS for TrueNAS API:**
   ```yaml
   config:
     truenas:
       protocol: "https"
       allowInsecure: false
   ```

2. **Restrict API Key Permissions:**
   - Create dedicated user for CSI
   - Grant minimal required permissions

3. **Network Security:**
   - Use VLANs to isolate storage traffic
   - Configure firewall rules
   - Consider VPN for remote access

### 8.2 Performance

1. **Dataset Configuration:**
   - Use SSD pools for high-performance workloads
   - Enable compression (lz4 recommended)
   - Consider deduplication for similar data

2. **NFS Tuning:**
   - Adjust NFS version (v4 recommended)
   - Configure appropriate timeouts
   - Consider NFS over RDMA for high-performance

3. **Storage Class Selection:**
   - Use fast storage classes for databases
   - Use standard storage classes for backups/archives

### 8.3 Backup Strategy

1. **TrueNAS Snapshots:**
   - Configure periodic snapshots of k8s-storage dataset
   - Use TrueNAS replication for off-site backups

2. **Kubernetes Backup:**
   - Use Velero for application-level backups
   - Backup PVCs and application data

### 8.4 High Availability

1. **Multiple TrueNAS Systems:**
   - Configure multiple storage classes pointing to different TrueNAS systems
   - Use Rancher storage class management for failover

2. **NFS Redundancy:**
   - Use TrueNAS High Availability (HA) if available
   - Configure multiple NFS shares for redundancy

## Step 9: Integration with Rancher

### 9.1 Make Storage Class Available in Rancher Projects

1. **Navigate to Project:**
   - Cluster Management → nprd-apps → Projects/Namespaces → Select Project

2. **Resource Quotas:**
   - Set storage quotas per project
   - Limit PVC count and total storage

### 9.2 Use in Rancher Workloads

1. **Deploy Workload:**
   - Workloads → Deploy → Configure → Volumes → Add Volume
   - Select: Use a Persistent Volume Claim
   - Choose: Create a new Persistent Volume Claim
   - Storage Class: `truenas-nfs`
   - Size: Specify desired size
   - Access Mode: ReadWriteMany (for NFS)

2. **Deploy and Verify:**
   - Workload should start with persistent storage
   - Data persists across pod restarts

## Configuration Reference

### Complete Helm Values Example

```yaml
# democratic-csi Helm values
# CSI Driver Configuration (required by chart)
csiDriver:
  name: truenas-nfs  # Must be unique per cluster
  enabled: true
  attachRequired: true
  podInfoOnMount: true

# Driver Configuration
driver:
  config:
    driver: freenas-api-nfs  # Use freenas-api-nfs for TrueNAS API-based NFS
    httpConnection:
      protocol: "https"
      host: "truenas.example.com"
      port: 443
      apiKey: "your-api-key-here"
      allowInsecure: false
    zfs:
      datasetParentName: "pool/k8s-storage"  # ZFS dataset name (without /mnt/ prefix)
      detachedSnapshotsDatasetParentName: "pool/k8s-storage-snapshots"
      datasetEnableQuotas: true
      datasetEnableReservation: false
      datasetPermissionsMode: "0777"
      datasetPermissionsUser: 0
      datasetPermissionsGroup: 0
    # NFS share configuration
    # IMPORTANT: Use shareHost (not server) for freenas-api-nfs driver
    nfs:
      shareHost: "truenas.example.com"  # NFS server hostname/IP
      shareAlldirs: false
      shareAllowedHosts: []
      shareAllowedNetworks: []
      shareMaprootUser: root
      shareMaprootGroup: root
      shareMapallUser: ""
      shareMapallGroup: ""

# Storage Classes
storageClasses:
  - name: truenas-nfs
    default: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: "nfs"
      parentDataset: "pool/k8s-storage"  # ZFS dataset name (without /mnt/ prefix)
      nfsServer: "192.168.9.10"  # Must match IP that NFS service is bound to
      nfsVersion: "4"
    # Using default mount options (no override needed in most cases)
    # If custom mount options needed, use array format:
    # mountOptions:
    #   - noatime
    #   - nfsvers=4
      
  - name: truenas-nfs-fast
    default: false
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: "nfs"
      parentDataset: "/mnt/ssd-pool/k8s-storage-fast"

# Controller settings
controller:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Node settings
node:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

## Troubleshooting

### PVC Mount Failures

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#storagepvc-mount-issues) for detailed troubleshooting of:
- NFS service binding issues (Connection refused)
- Mount option configuration
- Storage class parameter updates
- CSI node pod scheduling

### Key Learnings

1. **Always verify NFS service binding** - TrueNAS NFS service may only be bound to specific IP addresses. Test manual mounts before configuring CSI.

2. **Default mount options work fine** - No need to override with `nolock` or custom mount flags unless specifically required. If manual mount works with defaults, CSI will also work.

3. **Storage class parameters are immutable** - Cannot update storage class parameters after creation. Must delete and recreate storage class to change parameters.

4. **Test connectivity first** - Always test NFS connectivity from cluster nodes before deploying CSI:
   ```bash
   # Test port accessibility
   timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.9.10/2049'
   
   # Test manual mount
   sudo mount -t nfs 192.168.9.10:/mnt/pool/k8s-storage /tmp/test
   ```

## Security Considerations

### What Democratic CSI Does

1. **Creates datasets** for each PVC (e.g., `pool/dataset/pvc-xxxxx`)
2. **Creates NFS shares** for each dataset (if using NFS)
3. **Deletes datasets** when PVCs are deleted
4. **Deletes NFS shares** when volumes are removed

### Minimum Permissions Needed

- ✅ **Dataset operations** on parent dataset and children
- ✅ **NFS share operations** (if automated, otherwise manual setup)
- ✅ **API access** to TrueNAS management interface

### What's NOT Needed

- ❌ Full pool access
- ❌ System administration
- ❌ Access to other datasets
- ❌ Shell/SSH access (API only)

### Security Best Practices

1. **Use HTTPS for TrueNAS API** (set `truenas_protocol = "https"` in tfvars)
2. **Create dedicated user** with minimal permissions (not root)
3. **Restrict API key scope** to dataset management only
4. **Use VLANs** to isolate storage traffic
5. **Configure firewall rules** to limit access to necessary ports
6. **Rotate API keys** periodically
7. **Monitor API access logs** in TrueNAS

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

Or manually:
1. Edit `terraform/terraform.tfvars`
2. Run `./scripts/generate-helm-values-from-tfvars.sh`
3. Reinstall via Helm: `helm upgrade democratic-csi ...`

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

# Verify TrueNAS connectivity from nodes
WORKER_IP=$(kubectl get nodes -o wide | grep worker | head -1 | awk '{print $6}')
ssh ubuntu@$WORKER_IP "timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.9.10/2049' && echo 'Port 2049 accessible' || echo 'Port 2049 NOT accessible'"

# Test manual mount from node
ssh ubuntu@$WORKER_IP "sudo mkdir -p /tmp/test-nfs && sudo mount -t nfs 192.168.9.10:/mnt/SAS/RKE2 /tmp/test-nfs 2>&1 && echo 'Mount successful!' && ls -la /tmp/test-nfs | head -5 && sudo umount /tmp/test-nfs && sudo rmdir /tmp/test-nfs || echo 'Mount failed'"
```

## Additional Resources

- **Democratic CSI Documentation:** https://github.com/democratic-csi/democratic-csi
- **TrueNAS Documentation:** https://www.truenas.com/docs/
- **Rancher Storage Documentation:** https://rancher.com/docs/rancher/v2.7/en/storage/
- **Kubernetes CSI Documentation:** https://kubernetes-csi.github.io/docs/
- **Troubleshooting Guide:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Troubleshooting Checklist

- [ ] TrueNAS NFS service is enabled and running
- [ ] NFS share is configured and accessible
- [ ] User has write access to dataset (ownership or ACLs)
- [ ] User can create/delete child datasets (test with `zfs create/destroy`)
- [ ] API key is valid and has proper permissions
- [ ] Network connectivity from nodes to TrueNAS (ports 111, 2049, 443)
- [ ] Dataset path exists on TrueNAS
- [ ] `nfs-common` package installed on all nodes
- [ ] CSI driver pods are running (including on server nodes if needed)
- [ ] Storage class is created and default (if desired)
- [ ] PVC can be created and bound
- [ ] Pods can mount volumes successfully
- [ ] Helm values file is generated from Terraform variables

## Next Steps

1. ✅ Install democratic-csi (via Terraform or manually)
2. ✅ Configure TrueNAS backend (dataset, permissions, API key)
3. ✅ Create storage classes
4. ✅ Test with sample PVC
5. ✅ Deploy applications using persistent storage
6. ✅ Configure backups and monitoring
7. ✅ Document your specific configuration
