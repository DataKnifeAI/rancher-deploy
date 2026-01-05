# Default Storage Class Configuration

## Current Configuration

The `truenas-nfs` storage class is configured as **default** in your Helm values:

```yaml
storageClasses:
  - name: truenas-nfs
    default: true  # ← This makes it the default
```

## What "Default" Means

When a storage class is marked as **default**:
- ✅ PVCs created **without** specifying `storageClassName` will automatically use it
- ✅ Rancher UI will show it as the default option
- ✅ It's marked with the annotation: `storageclass.kubernetes.io/is-default-class: "true"`

## Important: Only One Default Allowed

⚠️ **Kubernetes only allows ONE default storage class at a time.**

If you already have a default storage class in your cluster, you have two options:

### Option 1: Replace Existing Default (Recommended)

Make `truenas-nfs` the new default:

```bash
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Find current default
kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'

# Remove default from existing storage class (replace <existing-sc> with actual name)
kubectl patch storageclass <existing-sc> -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'

# Set truenas-nfs as default
kubectl patch storageclass truenas-nfs -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

### Option 2: Keep Existing Default, Make truenas-nfs Non-Default

If you want to keep your current default storage class:

1. **Before installation**, edit `helm-values/democratic-csi-truenas.yaml`:
   ```yaml
   storageClasses:
     - name: truenas-nfs
       default: false  # ← Change to false
   ```

2. **Or after installation**, remove the default annotation:
   ```bash
   kubectl patch storageclass truenas-nfs -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
   ```

## Check Current Default Storage Class

```bash
export KUBECONFIG=~/.kube/nprd-apps.yaml

# List all storage classes with default status
kubectl get storageclass

# Find which one is default
kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'
```

## RKE2 Default Storage Class

RKE2 typically comes with a **local-path** storage class that may be set as default. This is fine for development but not ideal for production workloads that need shared storage.

**Recommendation:** Make `truenas-nfs` the default for production workloads that need:
- Shared storage across nodes
- Persistent data that survives pod restarts
- NFS-backed volumes

## Using Non-Default Storage Class

Even if `truenas-nfs` is not the default, you can still use it by explicitly specifying it:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  storageClassName: truenas-nfs  # ← Explicitly specify
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
```

## Verification After Installation

After installing democratic-csi, verify the default:

```bash
kubectl get storageclass truenas-nfs -o yaml | grep -A 1 "is-default-class"
```

Should show:
```yaml
storageclass.kubernetes.io/is-default-class: "true"
```

## Summary

- ✅ **Configured as default** in your Helm values
- ⚠️ **May conflict** with existing default storage class
- 🔧 **Installation script** will warn you if there's a conflict
- 📝 **You can change it** before or after installation
