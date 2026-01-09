#!/usr/bin/env bash
set -euo pipefail

# Script to create GitHub App and set up Kubernetes secrets for ARC
# Note: GitHub App creation must be done via web UI, this script helps with secret setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ORG_NAME="${GITHUB_ORG:-DataKnifeAI}"
APP_NAME="${GITHUB_APP_NAME:-ARC Runner Controller}"
NAMESPACE="${RUNNER_NAMESPACE:-managed-cicd}"
SECRET_NAME="${SECRET_NAME:-github-app-secret}"
CONTROLLER_SECRET_NAME="${CONTROLLER_SECRET_NAME:-controller-manager}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-actions-runner-system}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Create GitHub App secrets for GitHub Actions Runner Controller (ARC).

OPTIONS:
    -c, --cluster CLUSTER     Cluster name (nprd-apps or prd-apps) [required]
    -i, --app-id ID           GitHub App ID [required]
    -n, --installation-id ID  GitHub App Installation ID [required]
    -k, --private-key PATH    Path to GitHub App private key (.pem file) [required]
    -s, --skip-controller     Skip creating controller secret (only create runner secret)
    -r, --skip-runner         Skip creating runner secret (only create controller secret)
    -h, --help                Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_ORG               GitHub organization name (default: DataKnifeAI)
    GITHUB_APP_NAME          GitHub App name (default: ARC Runner Controller)
    RUNNER_NAMESPACE         Kubernetes namespace for runner secret (default: managed-cicd)
    SECRET_NAME              Name of the runner secret (default: github-app-secret)
    CONTROLLER_SECRET_NAME   Name of the controller secret (default: controller-manager)
    CONTROLLER_NAMESPACE     Namespace for controller secret (default: actions-runner-system)

EXAMPLES:
    # Create both secrets for nprd-apps cluster
    $0 -c nprd-apps -i 123456 -n 789012 -k /path/to/private-key.pem

    # Only create runner secret
    $0 -c nprd-apps -i 123456 -n 789012 -k /path/to/private-key.pem --skip-controller

    # Create secrets for both clusters
    $0 -c nprd-apps -i 123456 -n 789012 -k /path/to/private-key.pem
    $0 -c prd-apps -i 123456 -n 789012 -k /path/to/private-key.pem

GITHUB APP CREATION (Manual Step):
    1. Go to: https://github.com/organizations/${ORG_NAME}/settings/apps/new
    2. Configure the app:
       - Name: ${APP_NAME}
       - Homepage URL: https://github.com/${ORG_NAME}
       - Webhook: Unchecked
       - Repository permissions:
         * Actions: Read & Write
         * Metadata: Read-only
       - Organization permissions:
         * Self-hosted runners: Read & Write
       - Where can this GitHub App be installed?: Only on this account
    3. Click "Create GitHub App"
    4. Note the App ID (visible on the app page)
    5. Generate and download the private key
    6. Install the app on your organization
    7. Note the Installation ID (from the installation URL)

EOF
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

# Parse arguments
CLUSTER=""
APP_ID=""
INSTALLATION_ID=""
PRIVATE_KEY_PATH=""
SKIP_CONTROLLER=false
SKIP_RUNNER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -i|--app-id)
            APP_ID="$2"
            shift 2
            ;;
        -n|--installation-id)
            INSTALLATION_ID="$2"
            shift 2
            ;;
        -k|--private-key)
            PRIVATE_KEY_PATH="$2"
            shift 2
            ;;
        -s|--skip-controller)
            SKIP_CONTROLLER=true
            shift
            ;;
        -r|--skip-runner)
            SKIP_RUNNER=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$CLUSTER" ]]; then
    log_error "Cluster name is required (-c/--cluster)"
    usage
    exit 1
fi

if [[ "$CLUSTER" != "nprd-apps" && "$CLUSTER" != "prd-apps" ]]; then
    log_error "Invalid cluster name: $CLUSTER (must be 'nprd-apps' or 'prd-apps')"
    exit 1
fi

if [[ "$SKIP_RUNNER" == false ]]; then
    if [[ -z "$APP_ID" || -z "$INSTALLATION_ID" || -z "$PRIVATE_KEY_PATH" ]]; then
        log_error "Missing required arguments for runner secret: --app-id, --installation-id, --private-key"
        usage
        exit 1
    fi
fi

if [[ "$SKIP_CONTROLLER" == false ]]; then
    if [[ -z "$APP_ID" || -z "$INSTALLATION_ID" || -z "$PRIVATE_KEY_PATH" ]]; then
        log_error "Missing required arguments for controller secret: --app-id, --installation-id, --private-key"
        usage
        exit 1
    fi
fi

# Validate private key file
if [[ -n "$PRIVATE_KEY_PATH" && ! -f "$PRIVATE_KEY_PATH" ]]; then
    log_error "Private key file not found: $PRIVATE_KEY_PATH"
    exit 1
fi

# Set kubeconfig based on cluster
KUBECONFIG_FILE="$HOME/.kube/${CLUSTER}.yaml"
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
    log_error "Kubeconfig file not found: $KUBECONFIG_FILE"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"

log_info "Using cluster: $CLUSTER"
log_info "Using kubeconfig: $KUBECONFIG_FILE"

# Read private key
if [[ -n "$PRIVATE_KEY_PATH" ]]; then
    PRIVATE_KEY=$(cat "$PRIVATE_KEY_PATH")
    if [[ -z "$PRIVATE_KEY" ]]; then
        log_error "Private key file is empty: $PRIVATE_KEY_PATH"
        exit 1
    fi
fi

# Create runner secret
if [[ "$SKIP_RUNNER" == false ]]; then
    log_info "Creating runner secret '$SECRET_NAME' in namespace '$NAMESPACE'..."
    
    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_warning "Namespace '$NAMESPACE' does not exist. Creating it..."
        kubectl create namespace "$NAMESPACE"
        log_success "Namespace '$NAMESPACE' created"
    fi
    
    # Create or update the secret
    kubectl create secret generic "$SECRET_NAME" \
        -n "$NAMESPACE" \
        --from-literal=github_app_id="$APP_ID" \
        --from-literal=github_app_installation_id="$INSTALLATION_ID" \
        --from-literal=github_app_private_key="$PRIVATE_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Runner secret '$SECRET_NAME' created/updated in namespace '$NAMESPACE'"
    
    # Verify secret
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_success "Secret verified: $(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.name}')"
        log_info "Secret contains keys: $(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys | @tsv' 2>/dev/null || echo 'github_app_id, github_app_installation_id, github_app_private_key')"
    else
        log_error "Failed to verify secret creation"
        exit 1
    fi
fi

# Create controller secret
if [[ "$SKIP_CONTROLLER" == false ]]; then
    log_info "Creating controller secret '$CONTROLLER_SECRET_NAME' in namespace '$CONTROLLER_NAMESPACE'..."
    
    # Check if namespace exists
    if ! kubectl get namespace "$CONTROLLER_NAMESPACE" &>/dev/null; then
        log_warning "Namespace '$CONTROLLER_NAMESPACE' does not exist. Creating it..."
        kubectl create namespace "$CONTROLLER_NAMESPACE"
        log_success "Namespace '$CONTROLLER_NAMESPACE' created"
    fi
    
    # Create or update the secret
    kubectl create secret generic "$CONTROLLER_SECRET_NAME" \
        -n "$CONTROLLER_NAMESPACE" \
        --from-literal=github_app_id="$APP_ID" \
        --from-literal=github_app_installation_id="$INSTALLATION_ID" \
        --from-literal=github_app_private_key="$PRIVATE_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Controller secret '$CONTROLLER_SECRET_NAME' created/updated in namespace '$CONTROLLER_NAMESPACE'"
    
    # Verify secret
    if kubectl get secret "$CONTROLLER_SECRET_NAME" -n "$CONTROLLER_NAMESPACE" &>/dev/null; then
        log_success "Controller secret verified"
        log_info "Restarting controller deployment to pick up new secret..."
        if kubectl rollout restart deployment/gha-runner-scale-set-controller -n "$CONTROLLER_NAMESPACE" &>/dev/null; then
            log_success "Controller deployment restarted"
        else
            log_warning "Could not restart controller deployment (may not exist yet)"
        fi
    else
        log_error "Failed to verify controller secret creation"
        exit 1
    fi
fi

# Summary
echo ""
log_success "GitHub App secrets created successfully for cluster: $CLUSTER"
echo ""
echo "Next steps:"
if [[ "$SKIP_RUNNER" == false ]]; then
    echo "  1. Verify the AutoscalingRunnerSet references the secret:"
    echo "     spec.githubConfigSecret: $SECRET_NAME"
    echo ""
fi
if [[ "$SKIP_CONTROLLER" == false ]]; then
    echo "  2. Check controller pod status:"
    echo "     kubectl --kubeconfig $KUBECONFIG_FILE get pods -n $CONTROLLER_NAMESPACE"
    echo ""
fi
echo "  3. Check controller logs for any errors:"
echo "     kubectl --kubeconfig $KUBECONFIG_FILE logs -n $CONTROLLER_NAMESPACE -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50"
echo ""
