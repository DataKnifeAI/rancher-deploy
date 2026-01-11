#!/bin/bash

# MongoDB Community Operator Installation Script
# Installs MongoDB Community Operator CRDs and operator for MongoDB management
# Required for Graylog Helm chart deployments

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
MONGODB_OPERATOR_NAMESPACE="${MONGODB_OPERATOR_NAMESPACE:-mongodb}"
MONGODB_OPERATOR_RELEASE_NAME="${MONGODB_OPERATOR_RELEASE_NAME:-community-operator}"
MONGODB_OPERATOR_CHART="mongodb/community-operator"
MONGODB_HELM_REPO="https://mongodb.github.io/helm-charts"
# MongoDB Community Operator CRD URL
MONGODB_CRD_URL="https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/master/config/crd/bases/mongodbcommunity.mongodb.com_mongodbcommunity.yaml"

# Cluster selection
CLUSTER="${1:-nprd-apps}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}MongoDB Community Operator Installation${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if we're in the right directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi
echo "✓ kubectl found"

if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm not found${NC}"
    exit 1
fi
echo "✓ helm found"

# Set kubeconfig based on cluster
KUBECONFIG_FILE="$HOME/.kube/${CLUSTER}.yaml"
if [ -f "$KUBECONFIG_FILE" ]; then
    export KUBECONFIG="$KUBECONFIG_FILE"
    echo "✓ Using kubeconfig: $KUBECONFIG_FILE"
else
    echo -e "${YELLOW}⚠ Kubeconfig not found: $KUBECONFIG_FILE${NC}"
    echo "Using default kubeconfig"
fi

# Verify cluster access
echo -e "${YELLOW}Verifying cluster access...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot access Kubernetes cluster${NC}"
    exit 1
fi
echo "✓ Cluster access verified"
echo ""

# Check if already installed
if helm list -n "$MONGODB_OPERATOR_NAMESPACE" 2>/dev/null | grep -q "^${MONGODB_OPERATOR_RELEASE_NAME}\s"; then
    echo -e "${YELLOW}MongoDB Community Operator already installed${NC}"
    read -p "Do you want to reinstall? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing existing installation..."
        helm uninstall "$MONGODB_OPERATOR_RELEASE_NAME" -n "$MONGODB_OPERATOR_NAMESPACE" 2>/dev/null || true
        kubectl delete namespace "$MONGODB_OPERATOR_NAMESPACE" --timeout=2m 2>/dev/null || true
        echo "Waiting for cleanup..."
        sleep 5
    else
        echo "Installation cancelled"
        exit 0
    fi
fi

# Add MongoDB Helm repository
echo -e "${YELLOW}Adding MongoDB Helm repository...${NC}"
helm repo add mongodb "$MONGODB_HELM_REPO" 2>/dev/null || echo "Repository already added"
helm repo update
echo "✓ Helm repository added and updated"
echo ""

# Install MongoDB Community Operator CRDs first
# Note: The Helm chart may also include CRDs, but installing them separately
# ensures they're available and matches the pattern used by other operators
echo -e "${YELLOW}Installing MongoDB Community Operator CRDs...${NC}"
echo "CRD URL: $MONGODB_CRD_URL"
echo ""

# Apply CRDs with server-side apply if supported, otherwise regular apply
if kubectl apply --server-side -f "$MONGODB_CRD_URL" 2>/dev/null; then
    echo "✓ CRDs applied using server-side apply"
else
    echo "⚠ Server-side apply not supported, using regular apply"
    kubectl apply -f "$MONGODB_CRD_URL"
    echo "✓ CRDs applied"
fi

echo ""

# Install MongoDB Community Operator via Helm
echo -e "${YELLOW}Installing MongoDB Community Operator...${NC}"
echo "Chart: $MONGODB_OPERATOR_CHART"
echo "Namespace: $MONGODB_OPERATOR_NAMESPACE"
echo ""

helm install "$MONGODB_OPERATOR_RELEASE_NAME" "$MONGODB_OPERATOR_CHART" \
    --namespace "$MONGODB_OPERATOR_NAMESPACE" \
    --create-namespace \
    --set operator.watchNamespace='*' \
    --wait \
    --timeout 10m

echo ""
echo -e "${GREEN}✓ MongoDB Community Operator installed${NC}"
echo ""

# Wait for operator to be ready
echo -e "${YELLOW}Waiting for operator pods to be ready...${NC}"
# Wait for any pods in the namespace (Helm charts may use different labels)
sleep 5
kubectl wait --for=condition=ready pod --all -n "$MONGODB_OPERATOR_NAMESPACE" --timeout=5m 2>/dev/null || {
    echo -e "${YELLOW}⚠ Some pods may still be starting${NC}"
}

# Verify installation
echo ""
echo -e "${YELLOW}Verifying installation...${NC}"
echo ""

# Find the deployment name dynamically
DEPLOYMENT_NAME=$(kubectl get deployment -n "$MONGODB_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$DEPLOYMENT_NAME" ]; then
    echo "Rolling out deployment: $DEPLOYMENT_NAME..."
    kubectl rollout status "deployment/$DEPLOYMENT_NAME" -n "$MONGODB_OPERATOR_NAMESPACE" --timeout=5m || true
else
    echo "⚠ No deployment found, checking pods directly..."
fi

echo ""
echo "MongoDB Community Operator Pods:"
kubectl get pods -n "$MONGODB_OPERATOR_NAMESPACE"

echo ""
echo "MongoDB Community Operator CRDs:"
kubectl get crd | grep mongodbcommunity || echo "CRDs may still be installing..."

echo ""
echo "MongoDB Community Operator Deployments:"
kubectl get deployment -n "$MONGODB_OPERATOR_NAMESPACE"

# Check operator status
echo ""
echo -e "${YELLOW}Operator Status:${NC}"
if [ -n "$DEPLOYMENT_NAME" ] && kubectl get "deployment/$DEPLOYMENT_NAME" -n "$MONGODB_OPERATOR_NAMESPACE" &>/dev/null; then
    READY=$(kubectl get "deployment/$DEPLOYMENT_NAME" -n "$MONGODB_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get "deployment/$DEPLOYMENT_NAME" -n "$MONGODB_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ]; then
        echo -e "${GREEN}✓ Operator is ready (${READY}/${DESIRED} replicas)${NC}"
    else
        echo -e "${YELLOW}⚠ Operator is starting (${READY}/${DESIRED} replicas ready)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Operator deployment status unavailable (may still be installing)${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Create a MongoDB instance using MongoDBCommunity CR:"
echo ""
echo "   apiVersion: mongodbcommunity.mongodb.com/v1"
echo "   kind: MongoDBCommunity"
echo "   metadata:"
echo "     name: graylog-mongodb"
echo "     namespace: graylog"
echo "   spec:"
echo "     members: 3"
echo "     type: ReplicaSet"
echo "     version: \"7.0.5\""
echo "     security:"
echo "       authentication:"
echo "         modes: [\"SCRAM\"]"
echo "     users:"
echo "       - name: graylog"
echo "         db: admin"
echo "         passwordSecretRef:"
echo "           name: graylog-mongodb-password"
echo "         roles:"
echo "           - name: readWrite"
echo "             db: graylog"
echo ""
echo "2. Apply the MongoDB instance:"
echo "   kubectl apply -f mongodb-instance.yaml"
echo ""
echo "3. Install Graylog Helm chart:"
echo "   helm repo add graylog https://helm.graylog.org"
echo "   helm repo update"
echo "   helm install graylog graylog/graylog --namespace graylog --create-namespace"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n $MONGODB_OPERATOR_NAMESPACE"
echo "  kubectl get deployment -n $MONGODB_OPERATOR_NAMESPACE"
echo "  kubectl get mongodbcommunity -A"
echo "  kubectl api-resources | grep mongodbcommunity"
echo ""
