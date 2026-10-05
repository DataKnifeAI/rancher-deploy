# Default Storage Class Configuration

## Current Configuration

On the app clusters the default StorageClass is **`truenas-csi-nfs`** (official TrueNAS CSI driver, `csi.truenas.io`). Terraform sets it with `truenas_csi_storage_class_default = true` in `terraform.tfvars` (the variable defaults to `false`).

prd-apps also has two non-default classes from the same driver: `truenas-csi-nfs-no-mapall` and `truenas-csi-nfs-postgres`.

## What "Default" Means

When a storage class is marked as **default**:
- PVCs created **without** `storageClassName` use it
- Rancher UI shows it as the default option
- It carries the annotation `storageclass.kubernetes.io/is-default-class: "true"`

## Only One Default Allowed

Kubernetes expects exactly **one** default StorageClass. RKE2 doesn't ship a default one on these clusters, so `truenas-csi-nfs` is the only one.

To move the default to another class:

```bash
export KUBECONFIG=~/.kube/nprd-apps-rke2.yaml

# Find current default
kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'

# Remove default from the current class, then set it on the new one
kubectl patch storageclass truenas-csi-nfs -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
kubectl patch storageclass <new-sc> -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

Change `truenas_csi_storage_class_default` in `terraform.tfvars` too, or the next Terraform apply puts it back.

## Check Current Default Storage Class

```bash
kubectl get storageclass
```

## Using a Non-Default Storage Class

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  storageClassName: truenas-csi-nfs-postgres
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

democratic-csi (`truenas-nfs`) was removed on 2026-10-04; see [TRUENAS_CSI_MIGRATION.md](TRUENAS_CSI_MIGRATION.md) for the history.
