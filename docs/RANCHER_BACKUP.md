# Rancher Backup Operator

The [Rancher Backup operator](https://github.com/rancher/backup-restore-operator) backs up and restores Rancher's state (clusters, projects, users, settings) on the **manager (local) cluster**. It is included in the Terraform deploy plan and can also be installed manually.

## In the plan (Terraform)

When you run `terraform apply` with `install_rancher = true`, the deploy script installs the Rancher Backup operator on the manager cluster **after** Rancher is deployed:

- Helm repo: `https://charts.rancher.io`
- Namespace: `cattle-resources-system`
- Charts: `rancher-backup-crd` (CRDs), then `rancher-backup` (operator)

If the automatic install fails (e.g. chart version), install manually using the steps below.

## Manual install on the Rancher (manager) cluster

Use **kubectl** so that commands run against the manager cluster (set context or `KUBECONFIG` to the manager kubeconfig).

1. **Point kubectl at the manager cluster**
   ```bash
   # If using merged kubeconfig
   kubectl config use-context rancher-manager
   # Or set kubeconfig to the manager file
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get nodes   # verify you see manager nodes
   ```

2. **Install the operator with Helm**
   ```bash
   helm repo add rancher-charts https://charts.rancher.io --force-update
   helm repo update
   kubectl create namespace cattle-resources-system
   helm install rancher-backup-crd rancher-charts/rancher-backup-crd \
     -n cattle-resources-system --wait
   helm install rancher-backup rancher-charts/rancher-backup \
     -n cattle-resources-system --wait
   ```

3. **Verify**
   ```bash
   kubectl get pods -n cattle-resources-system
   helm list -n cattle-resources-system
   ```

## Backing up Rancher state

After the operator is installed, create a **Backup** custom resource. The operator will run a one-time backup (or use a schedule for recurring backups).

### One-time backup (default storage location)

The operator can use a default storage location (e.g. PVC) configured at install time. To run a one-time full backup:

```bash
kubectl config use-context rancher-manager   # or export KUBECONFIG
kubectl apply -f docs/rancher-backup-example.yaml
```

Then check status:

```bash
kubectl get backups -n cattle-resources-system
kubectl describe backup rancher-state-backup -n cattle-resources-system
```

When the backup is complete, copy the backup file off-cluster for disaster recovery (see [Where backups are stored](#where-backups-are-stored) below).

### Where backups are stored

The backup destination is configured **when the Rancher Backup operator is installed** (operator-level). Options:

| Install-time choice | Where backups go |
|---------------------|------------------|
| **No default** | You must set `storageLocation` on each Backup CR (e.g. S3 or a PVC). |
| **StorageClass** (e.g. `--set persistence.storageClass=standard`) | A PVC is created in `cattle-resources-system` and the operator writes `.tar.gz` files there. |
| **Existing PV** | Backups go to the chosen Persistent Volume. |
| **S3** (at install) | Backups go to the configured bucket/folder. |

**Our Terraform install** does not pass a storage location, so the operator may have **no default**. In that case either:

- Set **storageLocation** on the Backup CR (see [Rancher backup configuration](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/backup-configuration)), e.g. S3 or a `persistentVolume` with an existing PVC, or  
- Reinstall the operator with a default, e.g.  
  `helm upgrade --install rancher-backup rancher-charts/rancher-backup -n cattle-resources-system --set persistence.enabled=true --set persistence.storageClass=<your-storage-class> --wait`

**If you use a PVC** (default or per-Backup):

- Backups are `.tar.gz` files under the volume mounted in the operator pod (namespace `cattle-resources-system`).
- To see the PVC: `kubectl get pvc -n cattle-resources-system`
- To copy a backup out (replace `<pvc-name>` and `<backup-filename>.tar.gz`):
  ```bash
  kubectl run -it --rm copy-backup --image=busybox --restart=Never -n cattle-resources-system -- \
    sh -c "cp /path/on/pvc/<backup-filename>.tar.gz /tmp/ && cat /tmp/<backup-filename>.tar.gz" | cat > ./rancher-backup.tar.gz
  ```
  Or use `kubectl cp` with a pod that has the PVC mounted (e.g. the rancher-backup operator pod).

Use a StorageClass or PV with **reclaim policy Retain** so backups are not lost if the PVC is deleted.

### Example Backup CR

**docs/rancher-backup-example.yaml** in this repo defines a one-time full backup (`resourceSetName: rancher-resource-set-full`). For recurring backups, add `schedule` and `retentionCount`; see [Rancher Backup configuration](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/backup-configuration).

### Restore

To restore from a backup, create a **Restore** CR pointing at the backup filename and (if used) the same storage location and encryption secret. See [Rancher Restore configuration](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/restore-configuration) and [examples](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/examples).

## S3 bucket for backups

We use **RustFS** (S3-compatible) for backup storage. To use it (or AWS S3), create a bucket with **versioning** enabled. Optionally use lifecycle rules to expire old versions and control cost. See **[RANCHER_BACKUP_S3_BUCKET.md](RANCHER_BACKUP_S3_BUCKET.md)** for versioning vs object lock vs quota, and optional Terraform in `terraform/environments/rancher-backup-bucket/` to create an AWS S3 bucket.

## Links

- [Rancher Backup operator (GitHub)](https://github.com/rancher/backup-restore-operator)
- [Backup, Restore, and Disaster Recovery (Rancher docs)](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery)
- [VM rebuild and data](VM_REBUILD_AND_DATA.md) — using backups when rebuilding VMs
