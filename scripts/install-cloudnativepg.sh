#!/bin/bash

# CloudNativePG Installation Script
# Installs CloudNativePG operator for PostgreSQL management

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
CNPG_VERSION="${CNPG_VERSION:-1.28.0}"
CNPG_NAMESPACE="cnpg-system"
CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-${CNPG_VERSION}.yaml"

# Cluster selection
CLUSTER="${1:-nprd-apps}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CloudNativePG Installation${NC}"
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
if kubectl get namespace "$CNPG_NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}CloudNativePG namespace already exists${NC}"
    read -p "Do you want to reinstall? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing existing installation..."
        kubectl delete -f "$CNPG_MANIFEST_URL" --ignore-not-found=true || true
        kubectl delete namespace "$CNPG_NAMESPACE" --timeout=2m 2>/dev/null || true
        echo "Waiting for cleanup..."
        sleep 5
    else
        echo "Installation cancelled"
        exit 0
    fi
fi

# Install CloudNativePG operator
echo -e "${YELLOW}Installing CloudNativePG operator (version ${CNPG_VERSION})...${NC}"
echo "Manifest URL: $CNPG_MANIFEST_URL"
echo ""

# Try server-side apply first, fallback to regular apply
if kubectl apply --server-side -f "$CNPG_MANIFEST_URL" 2>/dev/null; then
    echo "✓ Applied using server-side apply"
else
    echo "⚠ Server-side apply not supported, using regular apply"
    kubectl apply -f "$CNPG_MANIFEST_URL"
fi

echo ""
echo -e "${GREEN}✓ CloudNativePG operator manifest applied${NC}"
echo ""

# Wait for operator to be ready
echo -e "${YELLOW}Waiting for operator to be ready...${NC}"
kubectl wait --for=condition=available deployment/cnpg-controller-manager \
    -n "$CNPG_NAMESPACE" \
    --timeout=5m || {
    echo -e "${YELLOW}⚠ Deployment may still be starting${NC}"
    echo "Checking current status..."
    kubectl get deployment -n "$CNPG_NAMESPACE"
}

# Verify installation
echo ""
echo -e "${YELLOW}Verifying installation...${NC}"
echo ""

echo "Rolling out deployment..."
kubectl rollout status deployment/cnpg-controller-manager -n "$CNPG_NAMESPACE" --timeout=5m || true

echo ""
echo "CloudNativePG Pods:"
kubectl get pods -n "$CNPG_NAMESPACE"

echo ""
echo "CloudNativePG CRDs:"
kubectl get crd | grep cnpg || echo "CRDs may still be installing..."

echo ""
echo "CloudNativePG Deployment:"
kubectl get deployment -n "$CNPG_NAMESPACE"

# Check operator status
echo ""
echo -e "${YELLOW}Operator Status:${NC}"
if kubectl get deployment cnpg-controller-manager -n "$CNPG_NAMESPACE" &>/dev/null; then
    READY=$(kubectl get deployment cnpg-controller-manager -n "$CNPG_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment cnpg-controller-manager -n "$CNPG_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ]; then
        echo -e "${GREEN}✓ Operator is ready (${READY}/${DESIRED} replicas)${NC}"
    else
        echo -e "${YELLOW}⚠ Operator is starting (${READY}/${DESIRED} replicas ready)${NC}"
    fi
else
    echo -e "${RED}✗ Operator deployment not found${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Create a PostgreSQL cluster using CloudNativePG:"
echo ""
echo "   apiVersion: postgresql.cnpg.io/v1"
echo "   kind: Cluster"
echo "   metadata:"
echo "     name: my-postgres-cluster"
echo "   spec:"
echo "     instances: 3"
echo "     imageName: ghcr.io/cloudnative-pg/postgresql:16.2"
echo "     storage:"
echo "       size: 10Gi"
echo "       storageClass: truenas-nfs"
echo ""
echo "2. Apply the cluster manifest:"
echo "   kubectl apply -f my-postgres-cluster.yaml"
echo ""
echo "3. Check cluster status:"
echo "   kubectl get cluster -A"
echo "   kubectl get pods -l cnpg.io/cluster=my-postgres-cluster"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n $CNPG_NAMESPACE"
echo "  kubectl logs -n $CNPG_NAMESPACE -l app.kubernetes.io/name=cloudnative-pg"
echo "  kubectl get cluster -A"
echo "  kubectl api-resources | grep cnpg"
echo ""
