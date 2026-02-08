# TrueNAS CSI Multi-Node Scheduling Fix

The official TrueNAS CSI driver has a limitation: `ControllerPublishVolume` only accepts the node where the controller pod runs. This prevents scheduling pods on other worker nodes.

**Upstream issue:** https://github.com/truenas/truenas-csi/issues/3

## Options

### 1. Use Democratic CSI (truenas-nfs) for flexible scheduling

Democratic CSI works on any node. Use it for workloads that need scheduling flexibility:

```yaml
storageClassName: truenas-nfs  # Democratic CSI
```

### 2. Wait for upstream fix

The issue has been reported. Once merged, update to the fixed image.

### 3. Build a patched image (until upstream merges)

**Fix:** Remove the node validation in `pkg/driver/controller.go` `ControllerPublishVolume`:

```go
// DELETE these 4 lines (around line 976):
// Validate node exists - in single-node deployments, check against our node ID
// In multi-node deployments, this should be expanded to track all registered nodes
if req.NodeId != s.driver.NodeID() {
    return nil, status.Errorf(codes.NotFound, "node %s not found", req.NodeId)
}
```

**Build:**
```bash
git clone https://github.com/truenas/truenas-csi
cd truenas-csi
# Edit pkg/driver/controller.go - remove the 4 lines above
make docker-build
docker tag truenas-csi:latest YOUR_REGISTRY/truenas-csi:multi-node
docker push YOUR_REGISTRY/truenas-csi:multi-node
```

Then set in `terraform.tfvars`:
```hcl
truenas_csi_image = "YOUR_REGISTRY/truenas-csi:multi-node"
```
