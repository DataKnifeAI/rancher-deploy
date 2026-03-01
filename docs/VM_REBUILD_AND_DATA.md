# Rebuilding Kubernetes VMs Without Losing Data

**Short answer:** You can rebuild the K8s VMs, but **Rancher and cluster state are lost** unless you back them up and restore after the rebuild. **Application data on TrueNAS-backed PVCs can survive** if you preserve the TrueNAS datasets and reattach the same storage.

## Where Data Lives

| Data | Location | Survives VM rebuild? |
|------|----------|---------------------|
| **Rancher state** (clusters, projects, users, tokens) | Manager cluster **etcd** (on manager VMs) | ❌ No (unless you backup/restore) |
| **Manager cluster** (RKE2 control plane) | Manager VMs **etcd** | ❌ No (unless you backup/restore) |
| **Downstream cluster** (nprd/prd/poc workloads, CRDs) | Each cluster’s **etcd** (on that cluster’s VMs) | ❌ No (unless you backup/restore) |
| **PVC data** (TrueNAS NFS / democratic-csi) | **TrueNAS** (external storage) | ✅ Yes, if you keep the datasets and don’t delete them |
| **VM local disk** (OS, RKE2 binaries, temp) | Each VM disk | ❌ No (VM is recreated) |

Rancher runs on the manager cluster and uses that cluster’s etcd. Downstream clusters each have their own etcd. Rebuilding VMs destroys those nodes and their etcd, so all cluster and Rancher state is lost unless you have backups.

## Rebuild Without Backups

If you **destroy and recreate** the K8s VMs with Terraform (e.g. `terraform destroy` then `terraform apply`):

- **Lost:** Rancher UI state, cluster registrations, all workloads (pods, deployments, etc.), any cluster-scoped config in etcd.
- **Preserved (if you don’t delete them):** Data on **TrueNAS** (NFS/democratic-csi). The volumes live on the storage server; the new clusters can use the same StorageClass and, if you recreate PVCs pointing at the same backend (e.g. same dataset/snapshots), you can reattach that data. You will need to recreate namespaces, PVCs, and workloads; only the underlying TrueNAS data can be reused.

So: **rebuild is possible, but you lose Rancher and all cluster state.** Only TrueNAS-backed data can be preserved and reattached manually.

## Rebuild With Minimal Data Loss (Using Backups)

To rebuild VMs and keep Rancher and cluster state:

1. **Before rebuild**
   - **RKE2 etcd snapshots** on manager and on each downstream cluster (e.g. `rke2 etcd-snapshot save` or scheduled snapshots).
   - **Rancher backup** (e.g. [Rancher Backup operator](https://github.com/rancher/backup-restore-operator); see [RANCHER_BACKUP.md](RANCHER_BACKUP.md) (installed on the manager cluster by this repo).

2. **Rebuild VMs**
   - Run `terraform destroy` (or replace the VMs), then `terraform apply` to recreate them with the same IPs/hostnames if possible.

3. **Restore**
   - Restore **RKE2** from etcd snapshots on the new nodes (per RKE2 docs).
   - Restore **Rancher** from the backup (per Rancher Backup docs).
   - Re-register downstream clusters in Rancher if they are new nodes/clusters, or restore their etcd from snapshots so Rancher can talk to the same clusters again.

The **Rancher Backup operator** is installed automatically on the manager cluster during deploy (see [RANCHER_BACKUP.md](RANCHER_BACKUP.md)); create a Backup CR to back up Rancher state. RKE2 etcd snapshots are not automated in this repo; add them separately if you need to restore the full control plane when rebuilding VMs.

## Summary

- **Rebuild VMs without any backup:** Rancher and all cluster state are lost; only TrueNAS PVC data can be preserved and reattached after recreating clusters and PVCs.
- **Rebuild VMs with etcd + Rancher backups:** You can restore Rancher and cluster state after the rebuild and keep control-plane and Rancher data; TrueNAS data remains the durable layer for application storage.
