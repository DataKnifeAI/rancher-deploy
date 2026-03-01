# Rolling Node Replacement (Replace Inaccessible VMs One by One)

When you don’t have access to some VMs (e.g. lost SSH key, broken node), you can replace them **one at a time**: Terraform destroys the old VM and creates a new one with the same IP and join config; the new node joins the cluster, state syncs, then you move to the next node. Cluster and Rancher state are preserved.

## Requirements

- **kubectl** and **kubeconfig** for the cluster you’re working on (from your laptop or from a node you can SSH to).
- **Terraform** and **`.keys/`** set up (SSH key, etc.) so the **new** VMs are built with your current key.
- Replace **one node at a time** and wait for the new node to be Ready before replacing the next.

## Which nodes can be replaced?

- **Secondary server nodes** (e.g. rancher-manager-2, rancher-manager-3, nprd-apps-2, nprd-apps-3) and **worker nodes** (e.g. nprd-apps-worker-1): safe to replace with the procedure below.
- **Primary nodes** (rancher-manager-1, nprd-apps-1, prd-apps-1, poc-apps-1): replacing them with the same Terraform config would create a **new** cluster (new VM boots as standalone primary). Do **not** use the simple replace flow for primaries; see [Primary node replacement](#primary-node-replacement) below.

## Procedure (one node at a time)

For each **non-primary** node you want to replace:

1. **Drain the node** (from a machine with kubeconfig for that cluster):
   ```bash
   kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data --force --grace-period=60
   ```
   If the node is unreachable, `--force` allows the drain to complete; workloads will be rescheduled to other nodes.

2. **Replace the VM with Terraform** (from repo root):
   ```bash
   cd terraform
   terraform apply -replace='<TERRAFORM_ADDRESS>'
   ```
   Use the address from the [Terraform address table](#terraform-addresses) below. Terraform will destroy the old VM and create a new one (same IP, hostname, join token). The new VM will join the cluster via cloud-init.

3. **Wait for the new node to be Ready**:
   ```bash
   kubectl get nodes -w
   ```
   Wait until the node (same hostname) shows `Ready`.

4. **Remove stale Node object** (if the old node is still listed as NotReady):
   ```bash
   kubectl delete node <NODE_NAME>
   ```
   Only delete the old/NotReady entry; the new node will have the same hostname and may have already replaced it.

5. **Uncordon** (optional; drain already marks the node unschedulable; after replace the new node is usually schedulable; if you see it Unschedulable, run):
   ```bash
   kubectl uncordon <NODE_NAME>
   ```

6. Repeat for the **next** node.

## Terraform addresses

Use these with `terraform apply -replace='...'` (from the `terraform/` directory).

### Manager cluster

| Node                 | Terraform address |
|----------------------|-------------------|
| rancher-manager-1     | `module.rancher_manager_primary` *(primary – see below)* |
| rancher-manager-2     | `module.rancher_manager_additional["manager-2"]` |
| rancher-manager-3     | `module.rancher_manager_additional["manager-3"]` |

### NPRD apps cluster

| Node                 | Terraform address |
|----------------------|-------------------|
| nprd-apps-1          | `module.nprd_apps_primary` *(primary – see below)* |
| nprd-apps-2          | `module.nprd_apps_additional["nprd-apps-2"]` |
| nprd-apps-3          | `module.nprd_apps_additional["nprd-apps-3"]` |
| nprd-apps-worker-1    | `module.nprd_apps_workers["nprd-apps-worker-1"]` |
| nprd-apps-worker-2    | `module.nprd_apps_workers["nprd-apps-worker-2"]` |
| …                    | … |

### PRD apps cluster

| Node                 | Terraform address |
|----------------------|-------------------|
| prd-apps-1           | `module.prd_apps_primary` *(primary – see below)* |
| prd-apps-2           | `module.prd_apps_additional["prd-apps-2"]` |
| prd-apps-3           | `module.prd_apps_additional["prd-apps-3"]` |
| prd-apps-worker-*   | `module.prd_apps_workers["prd-apps-worker-1"]` etc. |

### POC apps cluster

| Node                 | Terraform address |
|----------------------|-------------------|
| poc-apps-1           | `module.poc_apps_primary` *(primary – see below)* |
| poc-apps-2           | `module.poc_apps_additional["poc-apps-2"]` |
| poc-apps-3           | `module.poc_apps_additional["poc-apps-3"]` |
| poc-apps-worker-*    | `module.poc_apps_workers["poc-apps-worker-1"]` etc. |

## Primary node replacement

Replacing a **primary** node (rancher-manager-1, nprd-apps-1, prd-apps-1, poc-apps-1) with the same Terraform config would create a new VM that boots as a **standalone** primary (new cluster). Do **not** use `-replace=module.*_primary` as a normal rolling step.

Options:

- **Manager primary:** Ensure at least one manager node (e.g. manager-2 or manager-3) is healthy. Replace the primary only if you accept a short control-plane disruption and will fix token/join config manually, or use RKE2 procedures to promote another server and then replace the old primary (outside this doc).
- **Apps primary (nprd/prd/poc):** Token is stored in `config/.nprd-apps-token` (etc.) from the current primary. If you replace the apps primary, the new VM will generate a **new** token; secondaries and workers still use the **old** token and are already joined, so the cluster keeps running. To avoid confusion, replace **secondaries and workers first**; only replace the apps primary if necessary and be aware the token file will then refer to the new primary (for future runs).

## Helper script

From the repo root you can run:

```bash
./scripts/replace-node.sh <CLUSTER> <NODE_NAME>
```

Example:

```bash
./scripts/replace-node.sh manager rancher-manager-2
./scripts/replace-node.sh nprd-apps nprd-apps-worker-1
```

The script will:

1. Set kubectl context from `KUBECONFIG` or `~/.kube/config` (you must have the right context for that cluster).
2. Drain the node (with `--force` if needed).
3. Run `terraform apply -replace='...'` for the correct module address.
4. Wait for the new node to be Ready (with a timeout).
5. Delete the stale Node object if the old one is still present.

Requires: `kubectl`, `terraform`, and the cluster context selected.

## Summary

- Replace **one node at a time**; use **drain → replace → wait for Ready → delete stale node**.
- Use the Terraform addresses above for `terraform apply -replace='...'`.
- Replace **secondaries and workers** first; treat **primary** replacement as a special case (see Primary node replacement).
