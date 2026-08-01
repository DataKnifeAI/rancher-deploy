# TrueNAS CSI Multi-Node Scheduling Fix

The official TrueNAS CSI driver rejects `ControllerPublishVolume` for nodes other than the controller's own node ID when the driver runs in default `--mode=all`. Symptom: `rpc error: code = NotFound desc = node <name> not found`.

**Upstream issue:** https://github.com/truenas/truenas-csi/issues/3

## Required deploy flags (v0.18+ / IsNodeRegistered)

Split controller and node processes so the controller does not register a single node ID:

| Workload | Container | Required args |
|----------|-----------|---------------|
| `truenas-csi-controller` Deployment | `csi-controller` | `--mode=controller` |
| `truenas-csi-node` DaemonSet | `csi-node` | `--mode=node` |

With `--mode=controller`, `IsNodeRegistered` skips node-ID validation (empty registry), so attaches work on any worker. The Terraform template `terraform/templates/truenas-csi-driver.yaml.tpl` sets these flags. Keep image at `v0.18` (or newer) via `truenas_csi_image`.

After changing args, roll the controller/node pods, clear stuck `VolumeAttachment` objects if needed, and delete `ContainerCreating` pods so they re-attach.

## Alternatives

### 1. Use Democratic CSI (truenas-nfs) for flexible scheduling

Democratic CSI works on any node. Use it for workloads that need scheduling flexibility:

```yaml
storageClassName: truenas-nfs  # Democratic CSI
```

### 2. Hard-delete patch (legacy; prefer mode flags)

Older workaround: remove the node check in `ControllerPublishVolume`. Prefer `--mode=controller` / `--mode=node` on v0.18+ instead of rebuilding a patched image.
