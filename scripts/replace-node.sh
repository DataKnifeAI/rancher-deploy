#!/usr/bin/env bash
# Replace a single Kubernetes node VM (one-by-one rolling replace).
# Use when you don't have access to the VM: new VM joins the cluster, then old one is gone.
# See docs/ROLLING_NODE_REPLACEMENT.md for full procedure and Terraform addresses.
#
# Usage: ./scripts/replace-node.sh <CLUSTER> <NODE_NAME>
# Example: ./scripts/replace-node.sh manager rancher-manager-2
#          ./scripts/replace-node.sh nprd-apps nprd-apps-worker-1
#
# Requires: kubectl (with kubeconfig/context for that cluster), terraform

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <CLUSTER> <NODE_NAME>"
  echo "  CLUSTER:    manager | nprd-apps | prd-apps | poc-apps"
  echo "  NODE_NAME:  e.g. rancher-manager-2, nprd-apps-2, nprd-apps-worker-1"
  echo ""
  echo "Set KUBECONFIG or use kubectl context for the target cluster before running."
  exit 1
fi

CLUSTER="$1"
NODE_NAME="$2"

# Map (cluster, node_name) -> Terraform module address
get_replace_address() {
  local c="$1"
  local n="$2"
  case "$c" in
    manager)
      case "$n" in
        rancher-manager-1) echo "module.rancher_manager_primary" ;;
        rancher-manager-2) echo 'module.rancher_manager_additional["manager-2"]' ;;
        rancher-manager-3) echo 'module.rancher_manager_additional["manager-3"]' ;;
        *) echo "" ; return 1 ;;
      esac ;;
    nprd-apps)
      case "$n" in
        nprd-apps-1) echo "module.nprd_apps_primary" ;;
        nprd-apps-2) echo 'module.nprd_apps_additional["nprd-apps-2"]' ;;
        nprd-apps-3) echo 'module.nprd_apps_additional["nprd-apps-3"]' ;;
        nprd-apps-worker-1) echo 'module.nprd_apps_workers["nprd-apps-worker-1"]' ;;
        nprd-apps-worker-2) echo 'module.nprd_apps_workers["nprd-apps-worker-2"]' ;;
        nprd-apps-worker-3) echo 'module.nprd_apps_workers["nprd-apps-worker-3"]' ;;
        *) echo "" ; return 1 ;;
      esac ;;
    prd-apps)
      case "$n" in
        prd-apps-1) echo "module.prd_apps_primary" ;;
        prd-apps-2) echo 'module.prd_apps_additional["prd-apps-2"]' ;;
        prd-apps-3) echo 'module.prd_apps_additional["prd-apps-3"]' ;;
        prd-apps-worker-1) echo 'module.prd_apps_workers["prd-apps-worker-1"]' ;;
        prd-apps-worker-2) echo 'module.prd_apps_workers["prd-apps-worker-2"]' ;;
        prd-apps-worker-3) echo 'module.prd_apps_workers["prd-apps-worker-3"]' ;;
        *) echo "" ; return 1 ;;
      esac ;;
    poc-apps)
      case "$n" in
        poc-apps-1) echo "module.poc_apps_primary" ;;
        poc-apps-2) echo 'module.poc_apps_additional["poc-apps-2"]' ;;
        poc-apps-3) echo 'module.poc_apps_additional["poc-apps-3"]' ;;
        poc-apps-worker-1) echo 'module.poc_apps_workers["poc-apps-worker-1"]' ;;
        poc-apps-worker-2) echo 'module.poc_apps_workers["poc-apps-worker-2"]' ;;
        poc-apps-worker-3) echo 'module.poc_apps_workers["poc-apps-worker-3"]' ;;
        *) echo "" ; return 1 ;;
      esac ;;
    *) echo "" ; return 1 ;;
  esac
}

TF_ADDRESS="$(get_replace_address "$CLUSTER" "$NODE_NAME" || true)"
if [ -z "$TF_ADDRESS" ]; then
  echo "Unknown cluster/node: $CLUSTER / $NODE_NAME"
  echo "See docs/ROLLING_NODE_REPLACEMENT.md for valid Terraform addresses."
  exit 1
fi

# Warn on primary
case "$NODE_NAME" in
  rancher-manager-1|nprd-apps-1|prd-apps-1|poc-apps-1)
    echo "WARNING: $NODE_NAME is a primary node. Replacing it will create a new VM that boots as standalone (new cluster)."
    echo "Only proceed if you intend to replace the primary (e.g. after promoting another server)."
    read -r -p "Continue? [y/N] " ans
    case "$ans" in
      [yY]) ;;
      *) exit 0 ;;
    esac
    ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required. Install it and ensure KUBECONFIG or ~/.kube/config is set."
  exit 1
fi

echo "=== Replacing node: $NODE_NAME (cluster: $CLUSTER) ==="
echo "Terraform address: $TF_ADDRESS"
echo ""

# 1. Drain
echo "[1/4] Draining node $NODE_NAME..."
if kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
  kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=300s || true
else
  echo "  Node not found in cluster (may already be gone). Proceeding with replace."
fi

# 2. Terraform replace
echo ""
echo "[2/4] Replacing VM (terraform apply -replace)..."
cd "$TF_DIR"
terraform apply -replace="$TF_ADDRESS" -auto-approve

# 3. Wait for new node to be Ready
echo ""
echo "[3/4] Waiting for new node $NODE_NAME to be Ready (up to 5 minutes)..."
for i in $(seq 1 60); do
  if kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    echo "  Node $NODE_NAME is Ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "  Timeout waiting for Ready. Check: kubectl get nodes"
    exit 1
  fi
  sleep 5
done

# 4. If the node is still NotReady (stale object from old VM), delete it so the new node can register
STATUS="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$STATUS" != "True" ] && kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
  echo "[4/4] Removing stale NotReady node object..."
  kubectl delete node "$NODE_NAME"
  echo "  Re-run this script or wait for the new node to register and become Ready."
else
  echo "[4/4] Node $NODE_NAME is Ready."
fi

echo ""
echo "=== Done. Node $NODE_NAME has been replaced. ==="
echo "Replace the next node when ready (one at a time)."
