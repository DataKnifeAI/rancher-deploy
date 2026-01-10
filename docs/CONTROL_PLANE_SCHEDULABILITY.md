# Control Plane Node Schedulability Guide

**Last Updated**: January 2025

## Overview

This guide explains whether RKE2 control plane (server) nodes should have the worker role (be schedulable for workloads) in downstream clusters.

## Current Setup

Your downstream clusters (nprd-apps, prd-apps) have:
- **3 server nodes** (control plane + etcd) - VMs .110-112 (nprd) or .120-122 (prd)
- **3 worker nodes** (dedicated workloads) - VMs .113-115 (nprd) or .123-125 (prd)
- **Total: 6 nodes per cluster**

## RKE2 Default Behavior

By default, **RKE2 server nodes are NOT schedulable**. They have the following taints:

```bash
# Check taints on server nodes
kubectl get nodes -l node-role.kubernetes.io/control-plane=true --show-labels
kubectl describe node <server-node-name> | grep Taints

# Typical output:
# Taints: node-role.kubernetes.io/control-plane:NoSchedule
#         node-role.kubernetes.io/etcd:NoExecute
```

### Default Taints Explained

| Taint | Effect | Purpose |
|-------|--------|---------|
| `node-role.kubernetes.io/control-plane:NoSchedule` | NoSchedule | Prevents regular pods from scheduling |
| `node-role.kubernetes.io/etcd:NoExecute` | NoExecute | Can evict pods if etcd needs resources |
| `CriticalAddonsOnly` | NoSchedule | Only critical system pods allowed |

## Recommendation for Your Setup

### ✅ Keep Server Nodes Dedicated (Recommended)

**For your current configuration with dedicated worker nodes:**

```
✅ KEEP SERVER NODES NON-SCHEDULABLE
```

**Reasons:**
1. ✅ **You have dedicated worker nodes**: 3 worker nodes are sufficient for workloads
2. ✅ **Better isolation**: Control plane components (API server, etcd, scheduler) are protected from workload interference
3. ✅ **Production best practice**: Separation of concerns - control plane vs workloads
4. ✅ **Predictable performance**: Control plane operations (API calls, etcd writes) won't be affected by workload spikes
5. ✅ **Easier troubleshooting**: Clear separation makes issues easier to diagnose
6. ✅ **Resource guarantees**: Control plane components get dedicated resources

**When this is the right choice:**
- ✅ You have dedicated worker nodes (like your setup)
- ✅ Production environments
- ✅ High-availability requirements
- ✅ Performance-critical workloads
- ✅ Compliance/security requirements for isolation

### ❌ Make Server Nodes Schedulable (Alternative)

**When you should consider making server nodes schedulable:**

```
❌ MAKE SERVER NODES SCHEDULABLE ONLY IF:
```

**Reasons to make schedulable:**
1. ⚠️ **Limited resources**: Small clusters without dedicated workers
2. ⚠️ **Development/Testing**: Non-production environments where resource efficiency matters
3. ⚠️ **Small clusters**: 3-node clusters where all nodes need to run workloads
4. ⚠️ **Cost optimization**: Need to maximize resource utilization in small deployments

**When this is appropriate:**
- ⚠️ Small clusters (< 5 nodes total) without dedicated workers
- ⚠️ Development/test environments
- ⚠️ Resource-constrained environments
- ⚠️ Single-node or 3-node clusters (no separate workers)

## How to Check Current Status

```bash
# Check if server nodes are schedulable
export KUBECONFIG=~/.kube/nprd-apps.yaml

# List all nodes with their taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,ROLES:.metadata.labels.node-role

# Check specific server node
kubectl describe node nprd-apps-1 | grep -A 5 Taints

# Expected output for non-schedulable (current default):
# Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

## How to Make Server Nodes Schedulable

### Option 1: Remove Taint Manually (Post-Deployment)

```bash
# Remove NoSchedule taint from all server nodes
export KUBECONFIG=~/.kube/nprd-apps.yaml

# For each server node
for node in $(kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o name); do
  kubectl taint nodes ${node} node-role.kubernetes.io/control-plane:NoSchedule-
  echo "Removed taint from ${node}"
done

# Verify
kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

**Note:** The `NoExecute` taint on etcd should remain - it's for critical protection.

### Option 2: Configure in RKE2 Config (Pre-Deployment)

Edit the RKE2 configuration to prevent taints from being applied:

```bash
# On each server node, edit /etc/rancher/rke2/config.yaml
sudo vi /etc/rancher/rke2/config.yaml

# Add this configuration:
disable:
  - rke2-kube-proxy  # Not needed if you're not using it
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule-"  # Remove NoSchedule taint
```

**Better approach - use cloud-init script:**

Modify `terraform/modules/proxmox_vm/cloud-init-rke2.sh`:

```bash
# After RKE2 config creation, add:
if [ "${IS_RKE2_SERVER}" = "true" ] && [ "${MAKE_SCHEDULABLE}" = "true" ]; then
  echo "node-taint:" >> /etc/rancher/rke2/config.yaml
  echo "  - \"node-role.kubernetes.io/control-plane:NoSchedule-\"" >> /etc/rancher/rke2/config.yaml
  log "✓ Configured server node to be schedulable"
fi
```

Then restart RKE2 service:
```bash
sudo systemctl restart rke2-server
```

### Option 3: Use RKE2 Configuration Parameter

RKE2 doesn't have a built-in parameter to disable taints, but you can use a configuration file approach as shown in Option 2.

## Verifying Pod Scheduling

After making nodes schedulable, verify workloads can schedule:

```bash
# Test deployment on server node
kubectl run test-pod --image=nginx --overrides='
{
  "spec": {
    "nodeSelector": {
      "node-role.kubernetes.io/control-plane": ""
    }
  }
}'

# Check pod status
kubectl get pod test-pod -o wide

# Clean up
kubectl delete pod test-pod
```

## Impact Analysis

### Performance Impact

| Scenario | Control Plane Performance | Workload Performance |
|----------|---------------------------|----------------------|
| **Dedicated (Current)** | ⭐⭐⭐⭐⭐ Optimal | ⭐⭐⭐⭐⭐ Optimal |
| **Schedulable** | ⭐⭐⭐ Good (may degrade under load) | ⭐⭐⭐⭐ Good (competes with control plane) |

### Resource Utilization

| Configuration | Resource Efficiency | Isolation |
|---------------|---------------------|-----------|
| **Dedicated (Current)** | Lower (server nodes idle for workloads) | ⭐⭐⭐⭐⭐ Excellent |
| **Schedulable** | Higher (all nodes run workloads) | ⭐⭐⭐ Moderate |

## Rancher Registration Impact

**Important Note:** The `--worker` flag in Rancher system-agent registration:

```bash
--etcd --controlplane --worker
```

This flag **does NOT** remove taints or make nodes schedulable. It only:
- Registers the node with all three roles in Rancher UI
- Allows Rancher to recognize the node capabilities
- Does NOT change Kubernetes taints/scheduling behavior

**To actually make nodes schedulable, you must remove the taints separately** (see methods above).

## Best Practice Recommendations

### For Your Setup (6-node clusters with dedicated workers)

```yaml
Configuration: Keep Server Nodes Dedicated ✅

Benefits:
  - Better control plane stability
  - Predictable performance
  - Production-ready architecture
  - Clear resource boundaries
```

### For Small Clusters (3-node, no dedicated workers)

```yaml
Configuration: Make Server Nodes Schedulable ⚠️

Considerations:
  - Monitor control plane performance
  - Set resource requests/limits for workloads
  - Use pod disruption budgets
  - Consider upgrading to dedicated workers when possible
```

## Monitoring Considerations

If you make server nodes schedulable, monitor:

```bash
# Control plane component health
kubectl get componentstatuses

# API server latency
kubectl get --raw /metrics | grep apiserver_request_duration_seconds

# etcd performance
kubectl get --raw /metrics | grep etcd

# Node resource usage
kubectl top nodes
```

## Summary

### Current Setup Recommendation

**✅ Keep server nodes NON-SCHEDULABLE (current default)**

Your setup is ideal:
- ✅ 3 dedicated worker nodes for workloads
- ✅ 3 server nodes for control plane (protected)
- ✅ Production-ready architecture
- ✅ Better isolation and stability

### When to Change

Only make server nodes schedulable if:
- ⚠️ You have < 5 nodes total and no dedicated workers
- ⚠️ Development/test environments
- ⚠️ Resource constraints require it

### Migration Path (If Needed)

If you later want to make server nodes schedulable:

1. **Small clusters without workers**: Remove taints (see Option 1)
2. **Development environments**: Configure via RKE2 config (Option 2)
3. **Gradual migration**: Start with one server node, monitor, then expand

## References

- [RKE2 Configuration Options](https://docs.rke2.io/install/configuration)
- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Rancher Node Roles](https://rancher.com/docs/rancher/v2.8/en/cluster-admin/nodes/)
