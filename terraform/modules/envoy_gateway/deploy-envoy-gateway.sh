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
echo "Expected Gateway API bundle: $GATEWAY_API_VERSION (standard channel via gateway-crds-helm)"
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
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
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
# install.yaml bundles Gateway API (experimental by default) + Envoy Gateway CRDs.
# We install Gateway API from the *standard* channel via gateway-crds-helm so it
# matches RKE2 stock rke2-traefik-crd / manager, then layer EG CRDs + controller
# on top. Existing CRDs are only ever updated in place: deleting a CRD deletes
# every Gateway/Route/Policy object of that kind cluster-wide.
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
# Keep only Envoy Gateway CRDs from install.yaml (Gateway API comes from standard channel).
awk -v out="$WORKDIR/eg-only-crds.yaml" '
  function flush() {
    if (doc == "") return
    if (is_crd && doc ~ /gateway\.envoyproxy\.io/) print "---\n" doc > out
    doc = ""; is_crd = 0
  }
  /^---/ { flush(); next }
  /^kind: CustomResourceDefinition$/ { is_crd = 1 }
  { doc = doc $0 "\n" }
  END { flush() }
' "$WORKDIR/crds.yaml"
echo "  ✓ $(grep -c '^kind: CustomResourceDefinition$' "$WORKDIR/eg-only-crds.yaml") EG CRDs, $(grep -c '^kind:' "$WORKDIR/rest.yaml") other resources"
echo ""

# Step 2: Gateway API standard channel + EG CRDs first.
# Envoy Gateway >= v1.9 needs Gateway API v1.6 (TCPRoute/UDPRoute v1) before the
# controller is upgraded, otherwise those routes are skipped.
echo "[2/3] Applying Gateway API standard + Envoy Gateway CRDs (server-side)..."
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  CURRENT_BUNDLE=$(kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
  CURRENT_CHANNEL=$(kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')
  echo "  Existing Gateway API CRDs: bundle ${CURRENT_BUNDLE:-unknown} channel ${CURRENT_CHANNEL:-unknown}"
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is required to render gateway-crds-helm (standard channel)" >&2
  exit 1
fi
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=false \
  > "$WORKDIR/gateway-api-standard.yaml"
kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$WORKDIR/gateway-api-standard.yaml"
kubectl apply --server-side --force-conflicts --field-manager=envoy-gateway-installer -f "$WORKDIR/eg-only-crds.yaml"
# Established only exists on CRDs (skip ValidatingAdmissionPolicy objects).
kubectl get -f "$WORKDIR/gateway-api-standard.yaml" -o name 2>/dev/null | grep '^customresourcedefinition.apiextensions.k8s.io/' | \
  xargs -r kubectl wait --for=condition=Established --timeout=120s
kubectl wait --for=condition=Established --timeout=120s -f "$WORKDIR/eg-only-crds.yaml"
NEW_BUNDLE=$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
NEW_CHANNEL=$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')
echo "  ✓ CRDs established (Gateway API bundle $NEW_BUNDLE channel $NEW_CHANNEL)"
if [ -n "$GATEWAY_API_VERSION" ] && [ "$NEW_BUNDLE" != "$GATEWAY_API_VERSION" ]; then
  echo "  ⚠ gateway_api_version is $GATEWAY_API_VERSION but rendered standard bundle is $NEW_BUNDLE"
fi
if [ "$NEW_CHANNEL" != "standard" ]; then
  echo "ERROR: expected Gateway API channel=standard, got ${NEW_CHANNEL:-empty}" >&2
  exit 1
fi
# Game operators (palworld/dragonwilds/terraria/satisfactory) still speak
# TCPRoute/UDPRoute/TLSRoute v1alpha2. Standard channel stores v1 and leaves
# v1alpha2 unserved — re-enable served so those clients can reconcile until
# operators move to gateway-api v1 clients.
echo "  Keeping TCPRoute/UDPRoute/TLSRoute v1alpha2 served for legacy operator clients..."
for crd in tcproutes.gateway.networking.k8s.io udproutes.gateway.networking.k8s.io tlsroutes.gateway.networking.k8s.io; do
  if ! kubectl get crd "$crd" &>/dev/null; then
    continue
  fi
  kubectl get crd "$crd" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
changed = False
for v in d.get("spec", {}).get("versions", []):
  if v.get("name") == "v1alpha2" and not v.get("served", False):
    v["served"] = True
    changed = True
if changed:
  json.dump(d, sys.stdout)
' > "$WORKDIR/${crd}.patched.json" || true
  if [ -s "$WORKDIR/${crd}.patched.json" ]; then
    kubectl replace -f "$WORKDIR/${crd}.patched.json" >/dev/null
    echo "  ✓ ${crd}: v1alpha2 served=true"
  fi
done
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
    echo "  Check logs with: kubectl logs -n $NAMESPACE -l control-plane=envoy-gateway"
  }
fi

# Verify installation
echo ""
echo "Verifying Envoy Gateway installation..."
sleep 5

PODS_READY=0
for i in {1..30}; do
  READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l control-plane=envoy-gateway --no-headers 2>/dev/null | grep -c " Running " || true)
  TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l control-plane=envoy-gateway --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    PODS_READY=1
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "  Waiting for pods to be ready... ($READY_PODS/$TOTAL_PODS ready, attempt $i/30)"
    kubectl get pods -n "$NAMESPACE" -l control-plane=envoy-gateway || true
  fi
  sleep 2
done

if [ "$PODS_READY" -eq 1 ]; then
  echo "  ✓ Envoy Gateway pods are ready"
  kubectl get pods -n "$NAMESPACE" -l control-plane=envoy-gateway
else
  echo "  ⚠ Envoy Gateway pods may not be fully ready yet"
  echo "  Current pod status:"
  kubectl get pods -n "$NAMESPACE" -l control-plane=envoy-gateway || kubectl get pods -n "$NAMESPACE" || true
  echo "  Check status with: kubectl get pods -n $NAMESPACE"
fi

echo ""
echo "=========================================="
echo "Envoy Gateway Installation Complete"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "Envoy Gateway Version: $ENVOY_GATEWAY_VERSION"
echo "Note: Gateway API CRDs installed from standard channel; EG CRDs + controller layered on top"
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
