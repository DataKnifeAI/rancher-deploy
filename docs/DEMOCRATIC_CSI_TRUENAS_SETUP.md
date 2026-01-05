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
   - Name: `k8s-storage` (or your preferred name)
   - Type: Filesystem
   - Share Type: Generic
   - Enable compression (recommended: lz4)
   - Enable deduplication (optional, requires more RAM)

### 1.2 Configure NFS Share

1. **Enable NFS Service:**
   - Services → NFS → Enable

2. **Create NFS Share:**
   - Sharing → Unix Shares (NFS) → Add
   - Path: `/mnt/<pool>/k8s-storage`
   - Description: `Kubernetes Storage`
   - Enable: ✓
   - Network: `10.0.0.0/24` (your cluster subnet)
   - Authorized Networks: `10.0.0.0/24` (your cluster subnet)
   - Maproot User: `root`
   - Maproot Group: `wheel`
   - Save

### 1.3 Create Service Account (for TrueNAS API)

1. **Create API Key:**
   - System → API Keys → Add
   - Name: `k8s-csi`
   - Generate key and **save it securely**

2. **Note TrueNAS Details:**
   - TrueNAS Hostname/IP: `truenas.example.com` (or IP)
   - API Port: `443` (HTTPS) or `80` (HTTP)
   - Dataset Path: `/mnt/<pool>/k8s-storage`

## Step 2: Install Democratic CSI via Rancher

### 2.1 Using Rancher UI (Recommended)

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
# Basic Configuration
driver:
  name: truenas-nfs  # or truenas-iscsi for iSCSI
  enabled: true

# TrueNAS Configuration
config:
  truenas:
    host: "truenas.example.com"  # Your TrueNAS hostname/IP
    apiKey: "your-api-key-here"  # From Step 1.3
    protocol: "https"  # or "http"
    port: 443
    allowInsecure: false  # Set to true if using self-signed cert
    dataset: "/mnt/pool/k8s-storage"  # Your dataset path
    
# Storage Classes
storageClasses:
  - name: truenas-nfs
    default: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    parameters:
      fsType: "nfs"
      parentDataset: "/mnt/pool/k8s-storage"
```

5. **Click Install**

### 2.2 Using Helm CLI (Alternative)

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
  --set driver.name=truenas-nfs \
  --set driver.enabled=true \
  --set config.truenas.host=truenas.example.com \
  --set config.truenas.apiKey=your-api-key \
  --set config.truenas.protocol=https \
  --set config.truenas.port=443 \
  --set config.truenas.dataset=/mnt/pool/k8s-storage \
  --set storageClasses[0].name=truenas-nfs \
  --set storageClasses[0].default=true
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

### 7.3 Enable Debug Logging

Update democratic-csi values:

```yaml
driver:
  logLevel: debug
```

Or via Helm:

```bash
helm upgrade democratic-csi democratic-csi/democratic-csi \
  --namespace democratic-csi \
  --set driver.logLevel=debug
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
driver:
  name: truenas-nfs
  enabled: true
  logLevel: info

config:
  truenas:
    host: "truenas.example.com"
    apiKey: "your-api-key-here"
    protocol: "https"
    port: 443
    allowInsecure: false
    dataset: "/mnt/pool/k8s-storage"
    # Optional: NFS-specific settings
    nfs:
      server: "truenas.example.com"
      share: "/mnt/pool/k8s-storage"

# Storage Classes
storageClasses:
  - name: truenas-nfs
    default: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: "nfs"
      parentDataset: "/mnt/pool/k8s-storage"
      # Optional: NFS version
      nfsVersion: "4"
      
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

## Additional Resources

- **Democratic CSI Documentation:** https://github.com/democratic-csi/democratic-csi
- **TrueNAS Documentation:** https://www.truenas.com/docs/
- **Rancher Storage Documentation:** https://rancher.com/docs/rancher/v2.7/en/storage/
- **Kubernetes CSI Documentation:** https://kubernetes-csi.github.io/docs/

## Troubleshooting Checklist

- [ ] TrueNAS NFS service is enabled and running
- [ ] NFS share is configured and accessible
- [ ] API key is valid and has proper permissions
- [ ] Network connectivity from nodes to TrueNAS (ports 111, 2049, 443)
- [ ] Dataset path exists on TrueNAS
- [ ] `nfs-common` package installed on all nodes
- [ ] CSI driver pods are running
- [ ] Storage class is created and default (if desired)
- [ ] PVC can be created and bound
- [ ] Pods can mount volumes successfully

## Next Steps

1. ✅ Install democratic-csi
2. ✅ Configure TrueNAS backend
3. ✅ Create storage classes
4. ✅ Test with sample PVC
5. ✅ Deploy applications using persistent storage
6. ✅ Configure backups and monitoring
7. ✅ Document your specific configuration
