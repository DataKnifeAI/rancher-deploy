#!/bin/bash
set -e

# Script to deploy MetalLB to a Kubernetes cluster
# Usage: deploy-metallb.sh <kubeconfig_path> <metallb_version> <namespace> <cluster_name> <ip_pool_addresses>

KUBECONFIG="$1"
METALLB_VERSION="$2"
NAMESPACE="$3"
CLUSTER_NAME="$4"
IP_POOL_ADDRESSES="$5"

export KUBECONFIG

echo "=========================================="
echo "Deploying MetalLB to Kubernetes Cluster"
echo "=========================================="
echo "Kubeconfig: $KUBECONFIG"
echo "Cluster: $CLUSTER_NAME"
echo "MetalLB Version: $METALLB_VERSION"
echo "Namespace: $NAMESPACE"
if [ -n "$IP_POOL_ADDRESSES" ]; then
  echo "IP Pool: $IP_POOL_ADDRESSES"
fi
echo ""

# Verify cluster is accessible
echo "Verifying Kubernetes cluster access..."
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot access Kubernetes cluster. Check KUBECONFIG: $KUBECONFIG"
  exit 1
fi
kubectl cluster-info
echo ""

# Wait for cluster to be fully ready
echo "Checking cluster readiness..."
CLUSTER_READY=false
READY_RETRY=0
READY_MAX_RETRIES=60  # 5 minutes max (60 * 5 seconds)

while [ "$CLUSTER_READY" = false ] && [ $READY_RETRY -lt $READY_MAX_RETRIES ]; do
  READY_RETRY=$((READY_RETRY + 1))
  
  # Check API server is responsive
  if ! kubectl get nodes &>/dev/null; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - API server not ready, waiting..."
    sleep 5
    continue
  fi
  
  # Check that we have at least one node in Ready state
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  if [ "$READY_NODES" -eq 0 ]; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - No nodes in Ready state, waiting..."
    sleep 5
    continue
  fi
  
  # All checks passed
  echo "✓ Cluster is ready ($READY_NODES node(s) ready)"
  CLUSTER_READY=true
done

if [ "$CLUSTER_READY" = false ]; then
  echo "ERROR: Cluster not ready after $READY_MAX_RETRIES attempts (5 minutes)"
  echo "Current cluster status:"
  kubectl get nodes
  exit 1
fi

echo "Waiting 5 seconds for cluster to stabilize..."
sleep 5
echo "✓ Cluster is stable, proceeding with installation"
echo ""

# Step 1: Install MetalLB using official installation manifest
echo "[1/2] Installing MetalLB (version $METALLB_VERSION)..."
MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

# Check if MetalLB is already installed
if kubectl get namespace "$NAMESPACE" &>/dev/null && kubectl get deployment metallb-controller -n "$NAMESPACE" &>/dev/null; then
  echo "  MetalLB already installed, applying updated manifest..."
  kubectl apply -f "$MANIFEST_URL" || {
    echo "  ⚠ Apply had some conflicts, checking if resources were applied..."
    kubectl get deployment metallb-controller -n "$NAMESPACE" || {
      echo "ERROR: Deployment not found after apply attempt."
      exit 1
    }
  }
  echo "  ✓ MetalLB resources updated"
else
  echo "  Installing MetalLB from official manifest (first time installation)..."
  kubectl apply -f "$MANIFEST_URL" || {
    echo "ERROR: Failed to install MetalLB from manifest."
    exit 1
  }
  echo "  ✓ MetalLB manifest applied"
  
  # Wait for MetalLB CRDs to be established
  echo "  Waiting for MetalLB CRDs to be established..."
  CRD_ESTABLISHED=0
  for i in {1..30}; do
    if kubectl wait --for=condition=Established crd/ipaddresspools.metallb.io \
       crd/l2advertisements.metallb.io \
       --timeout=60s &>/dev/null 2>&1; then
      CRD_ESTABLISHED=1
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "    Waiting for CRDs... attempt $i/30"
    fi
    sleep 2
  done
  
  if [ "$CRD_ESTABLISHED" -eq 1 ]; then
    echo "  ✓ MetalLB CRDs established"
  else
    echo "  ⚠ MetalLB CRDs may not be fully established yet (installation continues)"
  fi
  
  # Wait for deployment to be available
  echo "  Waiting for MetalLB deployment to be ready..."
  kubectl wait --namespace "$NAMESPACE" \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=5m || {
    echo "  ⚠ Deployment may still be starting, checking status..."
    kubectl get deployment metallb-controller -n "$NAMESPACE" || true
    echo "  Check logs with: kubectl logs -n $NAMESPACE -l app=metallb"
  }
fi

# Step 2: Configure IP address pool if provided
if [ -n "$IP_POOL_ADDRESSES" ]; then
  echo ""
  echo "[2/2] Configuring MetalLB IP address pool..."
  
  # Check if IP pool already exists
  POOL_NAME="${CLUSTER_NAME}-pool"
  if kubectl get ipaddresspool "$POOL_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  IP address pool already exists, updating..."
    kubectl patch ipaddresspool "$POOL_NAME" -n "$NAMESPACE" --type merge -p "{\"spec\":{\"addresses\":[\"$IP_POOL_ADDRESSES\"]}}" || {
      echo "  ⚠ Failed to update IP pool, trying to recreate..."
      kubectl delete ipaddresspool "$POOL_NAME" -n "$NAMESPACE" --ignore-not-found=true
      sleep 2
    }
  fi
  
  # Create or recreate IP pool
  if ! kubectl get ipaddresspool "$POOL_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  Creating IP address pool: $POOL_NAME"
    kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $POOL_NAME
  namespace: $NAMESPACE
spec:
  addresses:
  - $IP_POOL_ADDRESSES
  autoAssign: true
EOF
    echo "  ✓ IP address pool created"
  else
    echo "  ✓ IP address pool updated"
  fi
  
  # Check if L2Advertisement exists
  L2_NAME="${CLUSTER_NAME}-l2"
  if ! kubectl get l2advertisement "$L2_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "  Creating L2Advertisement: $L2_NAME"
    kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: $L2_NAME
  namespace: $NAMESPACE
spec:
  ipAddressPools:
  - $POOL_NAME
EOF
    echo "  ✓ L2Advertisement created"
  else
    echo "  ✓ L2Advertisement already exists"
  fi
else
  echo ""
  echo "[2/2] Skipping IP pool configuration (ip_pool_addresses not provided)"
  echo "  Note: IP pool can be configured manually (see docs/METALLB_SETUP.md)"
fi

# Verify installation
echo ""
echo "Verifying MetalLB installation..."
sleep 5

PODS_READY=0
for i in {1..30}; do
  READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=metallb --no-headers 2>/dev/null | grep -c " Running " || echo "0")
  TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=metallb --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    PODS_READY=1
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "  Waiting for pods to be ready... ($READY_PODS/$TOTAL_PODS ready, attempt $i/30)"
    kubectl get pods -n "$NAMESPACE" -l app=metallb || true
  fi
  sleep 2
done

if [ "$PODS_READY" -eq 1 ]; then
  echo "  ✓ MetalLB pods are ready"
  kubectl get pods -n "$NAMESPACE" -l app=metallb
else
  echo "  ⚠ MetalLB pods may not be fully ready yet"
  echo "  Current pod status:"
  kubectl get pods -n "$NAMESPACE" -l app=metallb || kubectl get pods -n "$NAMESPACE" || true
  echo "  Check status with: kubectl get pods -n $NAMESPACE"
fi

echo ""
echo "=========================================="
echo "MetalLB Installation Complete"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "MetalLB Version: $METALLB_VERSION"
if [ -n "$IP_POOL_ADDRESSES" ]; then
  echo "IP Pool: $IP_POOL_ADDRESSES"
fi
echo ""
echo "Next steps:"
echo "  1. Verify installation:"
echo "     kubectl get pods -n $NAMESPACE"
echo "     kubectl get ipaddresspool -n $NAMESPACE"
echo ""
echo "  2. Configure services to use LoadBalancer type:"
echo "     kubectl patch svc <service-name> -n <namespace> -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"
echo ""
echo "  3. See docs/METALLB_SETUP.md for detailed configuration"
echo "=========================================="
