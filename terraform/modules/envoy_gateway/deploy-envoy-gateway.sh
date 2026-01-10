#!/bin/bash
set -e

# Script to deploy Envoy Gateway and Gateway API CRDs to a Kubernetes cluster
# Usage: deploy-envoy-gateway.sh <kubeconfig_path> <gateway_api_version> <envoy_gateway_version> <namespace> <cluster_name>

KUBECONFIG="$1"
GATEWAY_API_VERSION="$2"
ENVOY_GATEWAY_VERSION="$3"
NAMESPACE="$4"
CLUSTER_NAME="$5"

export KUBECONFIG

echo "=========================================="
echo "Deploying Envoy Gateway to Kubernetes Cluster"
echo "=========================================="
echo "Kubeconfig: $KUBECONFIG"
echo "Cluster: $CLUSTER_NAME"
echo "Envoy Gateway Version: $ENVOY_GATEWAY_VERSION"
echo "Namespace: $NAMESPACE"
echo "Note: Envoy Gateway install.yaml includes Gateway API CRDs automatically"
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

# Step 1: Check for and handle existing Gateway API CRDs
# Envoy Gateway install.yaml includes Gateway API CRDs. If CRDs from a previous install exist,
# we need to handle them to avoid annotation size conflicts.
echo "[1/2] Checking for existing Gateway API CRDs..."
GATEWAY_CRDS_EXIST=false
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  GATEWAY_CRDS_EXIST=true
  echo "  ⚠ Gateway API CRDs already exist"
  # Check if these are from Envoy Gateway (will have envoy-specific labels) or from a separate install
  if kubectl get crd gateways.gateway.networking.k8s.io -o yaml | grep -q "gateway.envoyproxy.io" 2>/dev/null; then
    echo "  CRDs appear to be from Envoy Gateway - will update via server-side apply"
  else
    echo "  CRDs appear to be from a separate Gateway API installation"
    echo "  Will delete and recreate to ensure compatibility with Envoy Gateway"
    echo "  Deleting existing Gateway API CRDs..."
    kubectl delete crd \
      gateways.gateway.networking.k8s.io \
      httproutes.gateway.networking.k8s.io \
      gatewayclasses.gateway.networking.k8s.io \
      grpcroutes.gateway.networking.k8s.io \
      tcproutes.gateway.networking.k8s.io \
      tlsroutes.gateway.networking.k8s.io \
      udproutes.gateway.networking.k8s.io \
      referencegrants.gateway.networking.k8s.io \
      backendtlspolicies.gateway.networking.k8s.io \
      --ignore-not-found=true --wait=true --timeout=60s || {
      echo "  ⚠ Some CRDs may still exist, continuing with installation..."
    }
    echo "  ✓ Existing Gateway API CRDs removed"
    GATEWAY_CRDS_EXIST=false
  fi
fi
echo ""

# Step 2: Install Envoy Gateway using official installation manifest
echo "[2/2] Installing Envoy Gateway (version $ENVOY_GATEWAY_VERSION)..."
MANIFEST_URL="https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"

# Check if Envoy Gateway is already installed
if kubectl get namespace "$NAMESPACE" &>/dev/null && kubectl get deployment envoy-gateway -n "$NAMESPACE" &>/dev/null; then
  echo "  Envoy Gateway already installed, applying updated manifest with server-side apply..."
  # Use server-side apply for updates to handle CRD conflicts properly
  kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$MANIFEST_URL" 2>&1 | grep -v "Too long: may not be more than" || {
    echo "  ⚠ Server-side apply had some conflicts, checking if resources were applied..."
    # Check if deployment was updated despite conflicts
    kubectl get deployment envoy-gateway -n "$NAMESPACE" || {
      echo "ERROR: Deployment not found after apply attempt."
      exit 1
    }
  }
  echo "  ✓ Envoy Gateway resources updated"
else
  echo "  Installing Envoy Gateway from official manifest (first time installation)..."
  # For new installations, use server-side apply which handles CRDs better
  kubectl apply --server-side --field-manager=envoy-gateway-installer -f "$MANIFEST_URL" || {
    echo "  ⚠ Server-side apply failed, trying regular apply..."
    # Regular apply, but filter out CRD annotation size errors (they're warnings, not fatal)
    kubectl apply -f "$MANIFEST_URL" 2>&1 | grep -v "Too long: may not be more than" || {
      echo "ERROR: Failed to install Envoy Gateway from manifest."
      echo ""
      echo "If you see CRD annotation errors above, the existing Gateway API CRDs conflict with Envoy Gateway's CRDs."
      echo "To resolve:"
      echo "  1. Delete existing Gateway API CRDs:"
      echo "     kubectl delete crd -l gateway.networking.k8s.io/bundle-version"
      echo "  2. Then re-run terraform apply"
      exit 1
    }
  }
  echo "  ✓ Envoy Gateway manifest applied"
  
  # Wait for Gateway API CRDs to be established
  echo "  Waiting for Gateway API CRDs to be established..."
  CRD_ESTABLISHED=0
  for i in {1..30}; do
    if kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io \
       crd/httproutes.gateway.networking.k8s.io \
       crd/gatewayclasses.gateway.networking.k8s.io \
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
    echo "  ✓ Gateway API CRDs established"
  else
    echo "  ⚠ Gateway API CRDs may not be fully established yet (installation continues)"
  fi
  
  # Wait for deployment to be available
  echo "  Waiting for Envoy Gateway deployment to be ready..."
  kubectl wait --for=condition=available deployment/envoy-gateway -n "$NAMESPACE" --timeout=5m || {
    echo "  ⚠ Deployment may still be starting, checking status..."
    kubectl get deployment envoy-gateway -n "$NAMESPACE" || true
    echo "  Check logs with: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=envoy-gateway"
  }
fi

# Verify installation
echo ""
echo "Verifying Envoy Gateway installation..."
sleep 5

PODS_READY=0
for i in {1..30}; do
  READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway --no-headers 2>/dev/null | grep -c " Running " || echo "0")
  TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    PODS_READY=1
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "  Waiting for pods to be ready... ($READY_PODS/$TOTAL_PODS ready, attempt $i/30)"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway || true
  fi
  sleep 2
done

if [ "$PODS_READY" -eq 1 ]; then
  echo "  ✓ Envoy Gateway pods are ready"
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway
else
  echo "  ⚠ Envoy Gateway pods may not be fully ready yet"
  echo "  Current pod status:"
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway || kubectl get pods -n "$NAMESPACE" || true
  echo "  Check status with: kubectl get pods -n $NAMESPACE"
fi

echo ""
echo "=========================================="
echo "Envoy Gateway Installation Complete"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "Envoy Gateway Version: $ENVOY_GATEWAY_VERSION"
echo "Note: Envoy Gateway includes Gateway API CRDs in its installation manifest"
echo ""
echo "Next steps:"
echo "  1. Verify installation:"
echo "     kubectl get pods -n $NAMESPACE"
echo "     kubectl get gatewayclass"
echo ""
echo "  2. Create GatewayClass (if not auto-created):"
echo "     kubectl apply -f - <<EOF"
echo "     apiVersion: gateway.networking.k8s.io/v1"
echo "     kind: GatewayClass"
echo "     metadata:"
echo "       name: eg"
echo "     spec:"
echo "       controllerName: gateway.envoyproxy.io/gatewayclass-eg"
echo "     EOF"
echo ""
echo "  3. Create Gateway resources (see docs/GATEWAY_API_SETUP.md)"
echo "=========================================="
