#!/bin/bash
set -eo pipefail

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
echo "Expected Gateway API bundle: $GATEWAY_API_VERSION (shipped in Envoy Gateway install.yaml)"
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

# Step 1: Download the release manifest and split CRDs from the rest.
# install.yaml bundles the Gateway API (experimental channel) and Envoy Gateway CRDs.
# Existing CRDs are only ever updated in place: deleting a CRD deletes every
# Gateway/Route/Policy object of that kind cluster-wide.
echo "[1/3] Downloading Envoy Gateway $ENVOY_GATEWAY_VERSION manifest..."
MANIFEST_URL="https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
curl -fsSL -o "$WORKDIR/install.yaml" "$MANIFEST_URL"
awk -v crds="$WORKDIR/crds.yaml" -v rest="$WORKDIR/rest.yaml" '
  function flush() { if (doc != "") { print "---\n" doc > (is_crd ? crds : rest) } doc = ""; is_crd = 0 }
  /^---/ { flush(); next }
  /^kind: CustomResourceDefinition$/ { is_crd = 1 }
  { doc = doc $0 "\n" }
  END { flush() }
' "$WORKDIR/install.yaml"
echo "  ✓ $(grep -c '^kind: CustomResourceDefinition$' "$WORKDIR/crds.yaml") CRDs, $(grep -c '^kind:' "$WORKDIR/rest.yaml") other resources"
echo ""

# Step 2: CRDs first. Envoy Gateway >= v1.9 requires the matching Gateway API CRDs
# (TCPRoute/UDPRoute v1) before the controller is upgraded, otherwise those routes are skipped.
echo "[2/3] Applying CRDs (server-side)..."
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  CURRENT_BUNDLE=$(kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
  echo "  Existing Gateway API CRDs: bundle ${CURRENT_BUNDLE:-unknown}"
fi
kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$WORKDIR/crds.yaml"
kubectl wait --for=condition=Established --timeout=120s -f "$WORKDIR/crds.yaml"
NEW_BUNDLE=$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
echo "  ✓ CRDs established (Gateway API bundle $NEW_BUNDLE)"
if [ -n "$GATEWAY_API_VERSION" ] && [ "$NEW_BUNDLE" != "$GATEWAY_API_VERSION" ]; then
  echo "  ⚠ gateway_api_version is $GATEWAY_API_VERSION but Envoy Gateway $ENVOY_GATEWAY_VERSION ships $NEW_BUNDLE"
fi
echo ""

# Step 3: Envoy Gateway controller, RBAC, webhook and certgen job
echo "[3/3] Installing Envoy Gateway (version $ENVOY_GATEWAY_VERSION)..."

# Check if Envoy Gateway is already installed
if kubectl get namespace "$NAMESPACE" &>/dev/null && kubectl get deployment envoy-gateway -n "$NAMESPACE" &>/dev/null; then
  echo "  Envoy Gateway already installed, applying updated manifest with server-side apply..."
  # The certgen Job template is immutable; a finished Job from a previous version must go first.
  # certgen does not overwrite existing control-plane cert secrets.
  kubectl delete job eg-gateway-helm-certgen -n "$NAMESPACE" --ignore-not-found=true --wait=true
  kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$WORKDIR/rest.yaml"
  kubectl rollout status deployment/envoy-gateway -n "$NAMESPACE" --timeout=5m
  echo "  ✓ Envoy Gateway resources updated"
else
  echo "  Installing Envoy Gateway from official manifest (first time installation)..."
  kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$WORKDIR/rest.yaml"
  echo "  ✓ Envoy Gateway manifest applied"

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
