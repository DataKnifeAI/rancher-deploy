#!/bin/bash

# GitHub Actions Runner Controller (ARC) Installation Script
# Installs official GitHub-supported ARC controller and CRDs
# Uses AutoscalingRunnerSet (official version, not legacy RunnerDeployment)
# Official documentation: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration - Official GitHub ARC (AutoscalingRunnerSet)
NAMESPACE="${ARC_NAMESPACE:-actions-runner-system}"
RELEASE_NAME="${ARC_RELEASE_NAME:-gha-runner-scale-set-controller}"
CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
# Official chart - no repo needed, uses OCI registry

# Cluster selection
CLUSTER="${1:-nprd-apps}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}GitHub Actions Runner Controller (ARC) Installation${NC}"
echo -e "${GREEN}Official GitHub-Supported Version${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "This installs the official GitHub-supported ARC controller."
echo "CRDs: AutoscalingRunnerSet, EphemeralRunnerSet, EphemeralRunner"
echo "Runner resources should be managed via Fleet after CRDs are installed."
echo ""
echo "Documentation: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller"
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

# Official chart uses OCI registry, no Helm repo needed
echo -e "${YELLOW}Using official GitHub OCI chart...${NC}"
echo "Chart: $CHART"
echo "✓ Using OCI registry (no Helm repo needed)"

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
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^${RELEASE_NAME}\s"; then
    echo -e "${YELLOW}ARC controller already installed${NC}"
    read -p "Do you want to upgrade/reinstall? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 0
    fi
    UPGRADE_MODE="upgrade"
else
    UPGRADE_MODE="install"
fi

# Install ARC controller (includes CRDs)
echo -e "${YELLOW}Installing official ARC controller and CRDs...${NC}"
echo "Chart: $CHART"
echo "Namespace: $NAMESPACE"
echo "Version: Official GitHub-supported version"
echo ""

if [ "$UPGRADE_MODE" = "upgrade" ]; then
    helm upgrade "$RELEASE_NAME" "$CHART" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 10m
else
    helm install "$RELEASE_NAME" "$CHART" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 10m
fi

echo ""
echo -e "${GREEN}✓ ARC controller installed${NC}"
echo ""

# Wait for pods to be ready
echo -e "${YELLOW}Waiting for controller pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=gha-runner-scale-set-controller -n "$NAMESPACE" --timeout=5m || {
    echo -e "${YELLOW}⚠ Some pods may still be starting${NC}"
}

# Verify installation
echo ""
echo -e "${YELLOW}Verifying installation...${NC}"
echo ""

echo "ARC Controller Pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=gha-runner-scale-set-controller || echo "Pods may still be starting..."

echo ""
echo "ARC CRDs (Official Version):"
kubectl get crd | grep -E "autoscalingrunnersets|ephemeralrunnersets|ephemeralrunners" || echo "CRDs may still be installing..."

echo ""
echo "Helm Release:"
helm list -n "$NAMESPACE"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Verify CRDs are installed:"
echo "   kubectl get crd | grep -E 'autoscalingrunnerset|ephemeralrunner'"
echo ""
echo "2. Configure runner resources via Fleet using AutoscalingRunnerSet:"
echo "   - Ensure Fleet GitRepo is configured"
echo "   - Fleet will now be able to validate AutoscalingRunnerSet resources"
echo ""
echo "3. Example Fleet resource (AutoscalingRunnerSet):"
echo "   apiVersion: actions.github.com/v1beta1"
echo "   kind: AutoscalingRunnerSet"
echo "   metadata:"
echo "     name: example-runner-scale-set"
echo "   spec:"
echo "     githubConfigUrl: https://github.com/your-org/your-repo"
echo "     githubConfigSecret: github-config-secret"
echo "     minRunners: 0"
echo "     maxRunners: 5"
echo ""
echo "4. Official Documentation:"
echo "   https://docs.github.com/en/actions/tutorials/use-actions-runner-controller"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get crd | grep -E 'autoscalingrunnerset|ephemeralrunner'"
echo "  kubectl get autoscalingrunnersets -A"
echo "  helm list -n $NAMESPACE"
echo ""
