# CloudNativePG Setup and Usage Guide

**Last Updated**: January 8, 2026  
**Status**: ✅ **FULLY AUTOMATED** via Terraform

This guide covers setting up and using CloudNativePG (CNPG) operator for PostgreSQL database management in your Rancher-managed RKE2 clusters.

## Overview

CloudNativePG is a Kubernetes operator that manages the full lifecycle of highly available PostgreSQL database clusters with primary/standby architecture using native streaming replication. It's designed specifically for Kubernetes and provides:

- ✅ Automated failover and high availability
- ✅ Native PostgreSQL streaming replication
- ✅ Declarative configuration
- ✅ Self-healing capabilities
- ✅ Rolling updates
- ✅ Scale up/down of read-only replicas
- ✅ Backup and disaster recovery
- ✅ TLS encryption support
- ✅ Prometheus monitoring integration

## Architecture

```
Kubernetes Cluster
├── CloudNativePG Operator (cnpg-system namespace)
│   └── Controller Manager Pod
├── PostgreSQL Clusters
│   ├── Primary Instance (read/write)
│   ├── Standby Instances (read-only replicas)
│   └── Persistent Volumes (TrueNAS NFS)
└── Custom Resources
    ├── Cluster (PostgreSQL cluster definition)
    ├── Backup (Backup operations)
    ├── Pooler (Connection pooling with PgBouncer)
    └── ScheduledBackup (Automated backups)
```

## Installation

### Automated Installation (Recommended)

CloudNativePG is **automatically deployed** via Terraform to nprd-apps, prd-apps, and poc-apps clusters:

1. **Configure in Terraform** (already configured):
   - Operator version: `1.28.0`
   - Namespace: `cnpg-system`
   - Installed on: `nprd-apps` and `prd-apps` clusters

2. **Run Terraform**:
   ```bash
   cd terraform
   terraform apply
   ```

   The operator will be automatically installed after clusters are ready.

### Manual Installation

If you need to install manually or reinstall:

```bash
# Install on nprd-apps cluster
./scripts/install-cloudnativepg.sh nprd-apps

# Install on prd-apps cluster
./scripts/install-cloudnativepg.sh prd-apps
```

### Verify Installation

```bash
# Check operator pods
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get pods -n cnpg-system

# Check CRDs
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get crd | grep cnpg

# Check operator status
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get deployment -n cnpg-system
```

Expected output:
```
NAME                                       READY   STATUS    RESTARTS   AGE
cnpg-controller-manager-6b9f78f594-xxxxx   1/1     Running   0          5m

NAME                                    CREATED AT
clusters.postgresql.cnpg.io             2026-01-08T20:37:48Z
backups.postgresql.cnpg.io              2026-01-08T20:37:48Z
poolers.postgresql.cnpg.io              2026-01-08T20:37:49Z
...
```

## Creating a PostgreSQL Cluster

### Basic Cluster Example

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-postgres-cluster
  namespace: default
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  
  # Storage configuration (uses TrueNAS NFS)
  # IMPORTANT: Always specify storageClass explicitly
  storage:
    size: 10Gi
    storageClass: truenas-nfs  # Required: TrueNAS NFS storage class
```

### Complete Cluster Example

See `test-postgres-cluster.yaml` for a complete example with:
- Custom PostgreSQL parameters
- Resource limits
- Bootstrap configuration
- Database and user creation

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-postgres-cluster
  namespace: default
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  
  storage:
    size: 10Gi
    storageClass: truenas-nfs
  
  # PostgreSQL configuration
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      effective_cache_size: "1GB"
  
  # Bootstrap with initial database
  bootstrap:
    initdb:
      database: myapp
      owner: myuser
      secret:
        name: postgres-credentials
      dataChecksums: true
      encoding: "UTF8"
  
  # Resource limits
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"
```

### Apply Cluster

```bash
# Apply to nprd-apps cluster
kubectl --kubeconfig ~/.kube/nprd-apps.yaml apply -f my-postgres-cluster.yaml

# Check cluster status
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get cluster.postgresql.cnpg.io

# Watch cluster creation
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get pods -l cnpg.io/cluster=my-postgres-cluster -w
```

## Cluster Management

### Check Cluster Status

```bash
# List all clusters
kubectl get cluster.postgresql.cnpg.io -A

# Get detailed cluster information
kubectl get cluster.postgresql.cnpg.io my-postgres-cluster -o yaml

# Check cluster phase
kubectl get cluster.postgresql.cnpg.io my-postgres-cluster -o jsonpath='{.status.phase}'

# View cluster events
kubectl describe cluster.postgresql.cnpg.io my-postgres-cluster
```

### Cluster Phases

- `Cluster phase: Pending` - Cluster is being created
- `Cluster phase: Cluster in healthy state` - Cluster is ready
- `Cluster phase: Cluster in degraded state` - Some issues detected

### View Pods

```bash
# List all pods for a cluster
kubectl get pods -l cnpg.io/cluster=my-postgres-cluster

# Check pod status
kubectl get pods -l cnpg.io/cluster=my-postgres-cluster -o wide
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS   AGE
my-postgres-cluster-1         1/1     Running   0          5m
my-postgres-cluster-2         1/1     Running   0          5m
my-postgres-cluster-3         1/1     Running   0          5m
```

### Connect to PostgreSQL

```bash
# Port-forward to primary instance
kubectl port-forward svc/my-postgres-cluster-rw 5432:5432

# Connect using psql
psql -h localhost -U myuser -d myapp

# Or connect directly to pod
kubectl exec -it my-postgres-cluster-1 -- psql -U myuser -d myapp
```

### Get Connection Details

```bash
# Get service endpoints
kubectl get svc -l cnpg.io/cluster=my-postgres-cluster

# Get read-write service (primary)
kubectl get svc my-postgres-cluster-rw

# Get read-only service (replicas)
kubectl get svc my-postgres-cluster-ro
```

## Storage Configuration

### Using TrueNAS NFS Storage

CloudNativePG integrates seamlessly with your TrueNAS NFS storage:

```yaml
spec:
  storage:
    size: 10Gi
    storageClass: truenas-nfs  # Your TrueNAS storage class
```

### Storage Requirements

- **Primary instance**: Requires ReadWriteOnce (RWO) storage
- **Replicas**: Each replica needs its own PVC
- **Recommended size**: Minimum 10Gi per instance
- **Storage class**: `truenas-nfs` (always specify explicitly)

⚠️ **Important**: Always explicitly specify `storageClass: truenas-nfs` in your cluster manifests, even though it's set as the default storage class on both clusters. This ensures:
- Consistent behavior across clusters
- Clear intent in your manifests
- Works even if default storage class changes

### Check Persistent Volumes

```bash
# List PVCs for cluster
kubectl get pvc -l cnpg.io/cluster=my-postgres-cluster

# Check PVC details
kubectl describe pvc my-postgres-cluster-1
```

## High Availability

### Failover

CloudNativePG automatically handles failover:

1. **Primary failure detection**: Operator detects primary pod failure
2. **Automatic promotion**: Standby with highest LSN is promoted to primary
3. **Replication update**: Other standbys reconnect to new primary
4. **Service update**: Read-write service points to new primary

### Manual Failover

```bash
# Promote a specific instance
kubectl cnpg promote my-postgres-cluster-2 \
  --cluster-name my-postgres-cluster \
  --namespace default
```

### Check Replication Status

```bash
# View cluster status
kubectl get cluster.postgresql.cnpg.io my-postgres-cluster -o yaml | grep -A 10 status

# Check replication lag
kubectl exec -it my-postgres-cluster-1 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

## Backup and Restore

### Create Backup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: my-backup
  namespace: default
spec:
  cluster:
    name: my-postgres-cluster
  target: primary
  method: barmanObjectStore
  data:
    compression: gzip
    encryption: AES256
    jobs: 2
  wal:
    compression: gzip
    encryption: AES256
    maxParallel: 1
```

### Scheduled Backups

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-backup
  namespace: default
spec:
  cluster:
    name: my-postgres-cluster
  schedule: "0 2 * * *"  # Daily at 2 AM
  backupOwnerReference: self
  suspend: false
```

### Restore from Backup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: restored-cluster
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  
  bootstrap:
    recovery:
      backup:
        name: my-backup
      source: my-postgres-cluster
```

## Monitoring

### Prometheus Integration

CloudNativePG includes built-in Prometheus metrics:

```yaml
spec:
  monitoring:
    customQueriesConfigMap:
    - key: queries
      name: cnpg-default-monitoring
    disableDefaultQueries: false
    enablePodMonitor: true  # Enable PodMonitor for Prometheus
```

### View Metrics

```bash
# Port-forward metrics endpoint
kubectl port-forward my-postgres-cluster-1 9187:9187

# Access metrics
curl http://localhost:9187/metrics
```

### Available Metrics

- `cnpg_postgresql_up` - PostgreSQL availability
- `cnpg_postgresql_replication_lag` - Replication lag
- `cnpg_postgresql_connections` - Connection count
- `cnpg_postgresql_wal_files` - WAL file count
- And many more...

## Scaling

### Scale Up Replicas

```bash
# Edit cluster to add more instances
kubectl edit cluster.postgresql.cnpg.io my-postgres-cluster

# Change instances: 3 to instances: 5
# Save and exit

# Watch new pods being created
kubectl get pods -l cnpg.io/cluster=my-postgres-cluster -w
```

### Scale Down Replicas

```bash
# Edit cluster to reduce instances
kubectl edit cluster.postgresql.cnpg.io my-postgres-cluster

# Change instances: 5 to instances: 3
# CloudNativePG will gracefully remove excess replicas
```

## Connection Pooling (PgBouncer)

### Create Pooler

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: my-pooler
  namespace: default
spec:
  cluster:
    name: my-postgres-cluster
  instances: 2
  type: rw  # or 'ro' for read-only
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "25"
```

### Use Pooler

```bash
# Get pooler service
kubectl get svc my-pooler-rw

# Connect through pooler
psql -h my-pooler-rw.default.svc.cluster.local -U myuser -d myapp
```

## Troubleshooting

### Cluster Stuck in Pending

```bash
# Check PVC status
kubectl get pvc -l cnpg.io/cluster=my-postgres-cluster

# Check pod events
kubectl describe pod my-postgres-cluster-1-initdb-xxxxx

# Check operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
```

### Primary Not Available

```bash
# Check cluster status
kubectl get cluster.postgresql.cnpg.io my-postgres-cluster -o yaml

# Check pod status
kubectl get pods -l cnpg.io/cluster=my-postgres-cluster

# View operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager
```

### Storage Issues

```bash
# Verify storage class exists
kubectl get storageclass truenas-nfs

# Check PVC binding
kubectl describe pvc my-postgres-cluster-1

# Verify TrueNAS connectivity
kubectl get pods -n democratic-csi
```

### Replication Issues

```bash
# Check replication status
kubectl exec -it my-postgres-cluster-1 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check WAL receiver status
kubectl exec -it my-postgres-cluster-2 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_wal_receiver;"
```

## Best Practices

### Resource Sizing

- **Small clusters** (< 10GB data): 256Mi-512Mi memory, 250m-500m CPU
- **Medium clusters** (10-100GB data): 1-2Gi memory, 1-2 CPU
- **Large clusters** (> 100GB data): 4Gi+ memory, 2-4 CPU

### Instance Count

- **Development**: 1-2 instances
- **Production**: 3+ instances (1 primary + 2+ standbys)
- **High availability**: 5+ instances for multi-zone deployments

### Storage

- Use `truenas-nfs` storage class for shared storage
- Allocate sufficient storage (10Gi minimum per instance)
- Monitor storage usage and set up alerts

### Backup Strategy

- Enable scheduled backups for production clusters
- Store backups in object storage (S3-compatible)
- Test restore procedures regularly
- Keep multiple backup retention policies

### Security

- Use Kubernetes secrets for credentials
- Enable TLS for PostgreSQL connections
- Restrict network policies
- Use RBAC for cluster access

## Useful Commands

```bash
# List all clusters
kubectl get cluster.postgresql.cnpg.io -A

# Get cluster details
kubectl get cluster.postgresql.cnpg.io my-postgres-cluster -o yaml

# View cluster pods
kubectl get pods -l cnpg.io/cluster=my-postgres-cluster

# Check cluster services
kubectl get svc -l cnpg.io/cluster=my-postgres-cluster

# View operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# List all CNPG CRDs
kubectl api-resources | grep cnpg

# Check PVCs
kubectl get pvc -l cnpg.io/cluster=my-postgres-cluster
```

## References

- [CloudNativePG Official Documentation](https://cloudnative-pg.io/documentation/)
- [CloudNativePG GitHub](https://github.com/cloudnative-pg/cloudnative-pg)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

## Summary

✅ **CloudNativePG is installed** on nprd-apps, prd-apps, and poc-apps clusters  
✅ **Operator is ready** to manage PostgreSQL clusters  
✅ **Storage integration** with TrueNAS NFS is configured  
✅ **High availability** with automatic failover is enabled  
✅ **Backup and restore** capabilities are available  

You can now create PostgreSQL clusters declaratively using Kubernetes manifests!
