# Migration: Democratic CSI → TrueNAS CSI

> **Done.** Every workload runs on TrueNAS CSI and democratic-csi was removed from all clusters and from this repo on 2026-10-04. Kept as history and as a template for future volume moves.

## Can we create new PVCs and remount?

**Yes.** The migration flow is: create new PVC with `truenas-csi-nfs` → copy data → update the workload to use the new PVC → delete the old PVC. The pod is updated to reference the new PVC; Kubernetes recreates the pod with the new volume mounted.

## Access modes (RWO vs RWX)

TrueNAS CSI supports both:

| Access mode | Protocol | Use case |
|-------------|----------|----------|
| **ReadWriteOnce (RWO)** | NFS or iSCSI | Single-pod, StatefulSets (e.g. Prometheus, Alertmanager) |
| **ReadWriteMany (RWX)** | NFS only | Multi-pod, shared storage |

Your existing Democratic CSI PVCs use **RWO**; the new driver supports that. Create new PVCs with `accessModes: [ReadWriteOnce]` for a 1:1 match.

## Compatibility

**The new TrueNAS CSI driver does NOT support existing Democratic CSI volumes.**

| Aspect | Democratic CSI (truenas-nfs) | TrueNAS CSI (truenas-csi-nfs) |
|--------|------------------------------|--------------------------------|
| Provisioner | truenas-nfs | csi.truenas.io |
| Volume path | `/mnt/SAS/RKE2/pvc-{uuid}` | `/mnt/SAS/pvc-{uuid}` (pool root) |
| Volume ID format | `pvc-{uuid}` | `SAS/pvc-{uuid}` |
| Storage class | truenas-nfs | truenas-csi-nfs |

Each CSI driver only manages volumes it created. A PV is bound to a specific driver; the kubelet calls that driver's node plugin to mount. TrueNAS CSI cannot mount Democratic CSI volumes.

**Requirement:** Keep Democratic CSI running as long as any PVCs use `truenas-nfs`. Removing it would break existing workloads.

---

## Migration Process

### Prerequisites

- Both CSI drivers deployed (Democratic + TrueNAS)
- Democratic CSI remains running for existing PVCs

### Per-Workload Migration

1. **Identify workloads** using `truenas-nfs`:
   ```bash
   kubectl get pvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage' | grep truenas-nfs
   ```

2. **Create migration pod** (or use existing app with downtime):
   ```yaml
   # migration-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-migration
     namespace: <TARGET_NAMESPACE>
   spec:
     containers:
       - name: migrate
         image: busybox:1.36
         command: ["sleep", "3600"]
         volumeMounts:
           - name: old
             mountPath: /old
           - name: new
             mountPath: /new
     volumes:
       - name: old
         persistentVolumeClaim:
           claimName: <OLD_PVC_NAME>
       - name: new
         persistentVolumeClaim:
           claimName: <NEW_PVC_NAME>
   ```

3. **Create new PVC** with TrueNAS CSI (match access mode to source: RWO or RWX):
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: <NEW_PVC_NAME>
     namespace: <NAMESPACE>
   spec:
     storageClassName: truenas-csi-nfs
     accessModes: [ReadWriteOnce]   # or ReadWriteMany for shared workloads
     resources:
       requests:
         storage: <SAME_OR_LARGER_SIZE>
   ```

4. **Copy data**:
   ```bash
   kubectl exec -n <NS> pvc-migration -- sh -c "cp -a /old/. /new/"
   # Or for large data: rsync -av /old/ /new/
   ```

5. **Update application** to use new PVC (update Deployment/StatefulSet `volumeClaimTemplates` or `volumes`).

6. **Verify** application works, then delete old PVC and migration pod.

### StatefulSet / volumeClaimTemplates

For StatefulSets with `volumeClaimTemplates`, you cannot change the storage class of existing PVCs. Options:

- **Option A:** Create new StatefulSet with new template, migrate data, delete old.
- **Option B:** Use `spec.volumeClaimTemplates` with new storage class and new StatefulSet name (new PVCs).

---

## Cleanup After Migration

Kubernetes and Terraform cleanup is complete (2026-10-04): no democratic-csi namespace, Helm release, CSIDriver, StorageClass, PV/PVC, CRD, RBAC or Fleet bundle on any cluster, and the stale `democratic_csi_config` output was removed from Terraform state.

### TrueNAS (manual)

democratic-csi used the `freenas-api-nfs` driver against `192.168.9.10`. TrueNAS CSI creates its volumes directly under the pool (`SAS/pvc-*`), so nothing below is used by it:

| Object | What to do |
|--------|------------|
| Dataset `SAS/RKE2` and children `SAS/RKE2/pvc-*` (e.g. `pvc-25d4289c-38a0-4c20-96ef-35d2cd91356d`, the old nprd Loki ingester) | Check nothing you want is left, then delete recursively |
| Dataset `SAS/RKE2-snapshots` (detached snapshots parent), if present | Delete |
| NFS shares with paths under `/mnt/SAS/RKE2/` | Delete (before the datasets) |
| Last democratic-csi API key (was `democratic_csi_api_key`, user `rke2`) | **Don't revoke.** It is the same key as `truenas_csi_api_key` (TrueNAS key ID 4), live in secret `truenas-csi/truenas-api-credentials` on nprd, prd and poc (checked 2026-10-04). Revoking it breaks TrueNAS CSI on every app cluster. To retire it, create a new key, roll it into `truenas_csi_api_key` and the three secrets, confirm the CSI pods are healthy, then revoke ID 4 |
| Older democratic-csi API keys (TrueNAS key IDs 1 and 2) | Revoke; nothing uses them |

---

## Democratic CSI PVCs on poc-apps (migrated)

At the time of migration:

| PVC | Size | Use |
|-----|------|-----|
| pvc-874bd628... | 200Gi | prometheus (managed-syslog) |
| pvc-9ef4cd52... | 20Gi | alertmanager (managed-syslog) |

Both were migrated to `truenas-csi-nfs`.

---

## Gaps / blockers

| Gap | Impact | Workaround |
|-----|--------|------------|
| **In-place PVC conversion** | Cannot change storage class of an existing PVC | Create new PVC, migrate data, switch workload |
| **StatefulSet PVC names** | volumeClaimTemplates create PVCs with fixed names | Create new StatefulSet with new template, migrate, then replace old |
| **Snapshots (TrueNAS 25.04)** | `VolumeSnapshot` fails: `Method does not exist` | Snapshots may work on TrueNAS 25.10+; omit for now |
| **Volume topology** | Both drivers use same pool; no topology constraints | No issue |
| **NFS vs iSCSI** | Current setup uses NFS only; iSCSI needs separate StorageClass | Add StorageClass with `protocol: iscsi` if needed |

**Summary:** No blocking gaps. Migration is feasible for all current workloads (Prometheus, Alertmanager). Use copy-based migration and keep both drivers running until migration is complete.
