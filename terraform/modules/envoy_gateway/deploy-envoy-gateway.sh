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
echo "Gateway API Version: $GATEWAY_API_VERSION"
echo "Envoy Gateway Version: $ENVOY_GATEWAY_VERSION"
echo "Namespace: $NAMESPACE"
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

# Step 1: Install Gateway API CRDs
echo "[1/3] Installing Gateway API CRDs (version $GATEWAY_API_VERSION)..."
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  echo "  Gateway API CRDs already exist, skipping installation"
  echo "  If you need to update, delete existing CRDs first:"
  echo "    kubectl delete crd -l gateway.networking.k8s.io/bundle-version"
else
  echo "  Applying Gateway API CRDs..."
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  
  # Wait for CRDs to be established
  echo "  Waiting for CRDs to be established..."
  CRD_ESTABLISHED=0
  for i in {1..30}; do
    if kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io \
       crd/httproutes.gateway.networking.k8s.io \
       crd/gatewayclasses.gateway.networking.k8s.io \
       --timeout=60s &>/dev/null; then
      CRD_ESTABLISHED=1
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "    Waiting for CRDs... attempt $i/30"
    fi
    sleep 2
  done
  
  if [ "$CRD_ESTABLISHED" -eq 1 ]; then
    echo "  ✓ Gateway API CRDs installed and established"
  else
    echo "  ⚠ Gateway API CRDs installed but not yet established"
    echo "  Installation will continue, but CRDs may not be ready yet"
  fi
fi
echo ""

# Step 2: Add Envoy Gateway Helm repository
echo "[2/3] Adding Envoy Gateway Helm repository..."
helm repo add envoy-gateway https://gateway.envoyproxy.io/helm-releases --force-update || true
helm repo update
echo "  ✓ Helm repository added and updated"
echo ""

# Step 3: Install Envoy Gateway
echo "[3/3] Installing Envoy Gateway (version $ENVOY_GATEWAY_VERSION)..."
if helm list -n "$NAMESPACE" | grep -q "envoy-gateway"; then
  echo "  Envoy Gateway already installed, upgrading to version $ENVOY_GATEWAY_VERSION..."
  helm upgrade envoy-gateway envoy-gateway/envoy-gateway \
    --namespace "$NAMESPACE" \
    --version "$ENVOY_GATEWAY_VERSION" \
    --create-namespace \
    --wait \
    --timeout 5m \
    --set config.envoyGateway.gateway.controllerName=gateway.envoyproxy.io/gatewayclass-eg
else
  echo "  Installing Envoy Gateway..."
  helm install envoy-gateway envoy-gateway/envoy-gateway \
    --namespace "$NAMESPACE" \
    --version "$ENVOY_GATEWAY_VERSION" \
    --create-namespace \
    --wait \
    --timeout 5m \
    --set config.envoyGateway.gateway.controllerName=gateway.envoyproxy.io/gatewayclass-eg
fi

# Verify installation
echo ""
echo "Verifying Envoy Gateway installation..."
sleep 5

PODS_READY=0
for i in {1..30}; do
  READY_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=envoy-gateway --no-headers 2>/dev/null | wc -l || echo "0")
  
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
    PODS_READY=1
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "  Waiting for pods to be ready... ($READY_PODS/$TOTAL_PODS ready, attempt $i/30)"
  fi
  sleep 2
done

if [ "$PODS_READY" -eq 1 ]; then
  echo "  ✓ Envoy Gateway pods are ready"
else
  echo "  ⚠ Envoy Gateway pods may not be fully ready yet"
  echo "  Check status with: kubectl get pods -n $NAMESPACE"
fi

echo ""
echo "=========================================="
echo "Envoy Gateway Installation Complete"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "Gateway API Version: $GATEWAY_API_VERSION"
echo "Envoy Gateway Version: $ENVOY_GATEWAY_VERSION"
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
