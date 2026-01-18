#!/bin/bash
set -e

# Script to remove MetalLB from all clusters
# Usage: remove-metallb.sh

echo "=========================================="
echo "Removing MetalLB from all clusters"
echo "=========================================="
echo ""

CLUSTERS=("nprd-apps" "prd-apps" "poc-apps")

for CLUSTER in "${CLUSTERS[@]}"; do
  echo "Processing cluster: $CLUSTER"
  KUBECONFIG_FILE="$HOME/.kube/${CLUSTER}.yaml"
  
  if [ ! -f "$KUBECONFIG_FILE" ]; then
    echo "  ⚠ Kubeconfig not found: $KUBECONFIG_FILE"
    echo "  Skipping cluster $CLUSTER"
    echo ""
    continue
  fi
  
  export KUBECONFIG="$KUBECONFIG_FILE"
  
  if ! kubectl cluster-info &>/dev/null; then
    echo "  ⚠ Cannot access cluster: $CLUSTER"
    echo "  Skipping cluster $CLUSTER"
    echo ""
    continue
  fi
  
  echo "  Removing MetalLB from cluster: $CLUSTER"
  
  # Delete MetalLB namespace (this will remove all MetalLB resources)
  if kubectl get namespace metallb-system &>/dev/null; then
    echo "    Deleting MetalLB namespace..."
    kubectl delete namespace metallb-system --timeout=2m || {
      echo "    ⚠ Failed to delete namespace, trying force delete..."
      kubectl delete namespace metallb-system --force --grace-period=0 --timeout=30s || true
    }
    echo "    ✓ MetalLB namespace deleted"
  else
    echo "    ✓ MetalLB namespace already removed"
  fi
  
  # Clean up any orphaned MetalLB CRDs (if any)
  echo "    Checking for MetalLB CRDs..."
  if kubectl get crd ipaddresspools.metallb.io &>/dev/null 2>&1; then
    echo "    Deleting MetalLB CRDs..."
    kubectl delete crd ipaddresspools.metallb.io l2advertisements.metallb.io bfdprofiles.metallb.io bgpadvertisements.metallb.io bgppeers.metallb.io --ignore-not-found=true || true
    echo "    ✓ MetalLB CRDs removed"
  else
    echo "    ✓ No MetalLB CRDs found"
  fi
  
  echo ""
done

echo "=========================================="
echo "MetalLB removal complete"
echo "=========================================="
