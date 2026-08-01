# TrueNAS CSI Multi-Node Scheduling Fix

The official TrueNAS CSI driver rejects `ControllerPublishVolume` for nodes other than the controller's own node ID when the driver runs in default `--mode=all`. Symptom: `rpc error: code = NotFound desc = node <name> not found`.

## Canonical fix (upstream)

Upstream fixed this by splitting CSI process modes in the deploy manifest:

| Reference | Link |
|-----------|------|
| Issue | https://github.com/truenas/truenas-csi/issues/3 |
| Deploy commit | https://github.com/truenas/truenas-csi/commit/6201fce8041fe1bac3f7f693853c4e5f2f21137e (`set explicit --mode flags in deploy manifest (fixes #3)`) |
| Current deploy YAML | https://github.com/truenas/truenas-csi/blob/master/deploy/truenas-csi-driver.yaml |

| Workload | Container | Required args |
|----------|-----------|---------------|
| `truenas-csi-controller` Deployment | `csi-controller` | `--mode=controller` |
| `truenas-csi-node` DaemonSet | `csi-node` | `--mode=node` |

With `--mode=controller`, `IsNodeRegistered` skips node-ID validation (empty registry), so attaches work on any worker. This repo's Terraform template (`terraform/templates/truenas-csi-driver.yaml.tpl`) mirrors that upstream deploy change. Keep image at `v0.18` (or newer) via `truenas_csi_image`.

After changing args, roll the controller/node pods, clear stuck `VolumeAttachment` objects if needed, and delete `ContainerCreating` pods so they re-attach.

## Alternatives

### 1. Use Democratic CSI (truenas-nfs) for flexible scheduling

Democratic CSI works on any node. Use it for workloads that need scheduling flexibility:

```yaml
storageClassName: truenas-nfs  # Democratic CSI
```

### 2. Hard-delete patch (legacy / optional)

Older local workaround before upstream mode flags: remove the node check in `ControllerPublishVolume` and rebuild a patched image. Prefer the upstream `--mode=controller` / `--mode=node` deploy flags instead; keep this only if you cannot run a mode-split deploy.
