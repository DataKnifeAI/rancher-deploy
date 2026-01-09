#!/usr/bin/env bash
set -euo pipefail

# Complete ARC setup with existing GitHub App

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# These values should be provided as parameters or prompted
APP_ID=""
APP_NAME=""
ORG_NAME=""

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

prompt() {
    echo -e "${CYAN}?${NC} $1"
}

echo "=================================================="
echo "  Complete ARC Setup"
echo "=================================================="
echo ""

log_info "Step 0: Collect GitHub App Information"
echo ""
prompt "Enter your GitHub App ID:"
read -r APP_ID

if [[ -z "$APP_ID" ]]; then
    echo "App ID cannot be empty. Exiting."
    exit 1
fi

prompt "Enter your GitHub App name (optional):"
read -r APP_NAME
APP_NAME="${APP_NAME:-GitHub App}"

prompt "Enter your GitHub organization name:"
read -r ORG_NAME

if [[ -z "$ORG_NAME" ]]; then
    echo "Organization name cannot be empty. Exiting."
    exit 1
fi

echo ""
log_success "GitHub App information collected!"
echo ""
echo "App Details:"
echo "  • Name: ${APP_NAME}"
echo "  • App ID: ${APP_ID}"
echo "  • Organization: ${ORG_NAME}"
echo ""

echo "=================================================="
echo "  Remaining Steps"
echo "=================================================="
echo ""

log_info "Step 1: Generate Private Key (if not already done)"
echo ""
echo "1. Go to your app page:"
echo -e "${CYAN}https://github.com/organizations/${ORG_NAME}/settings/apps/${APP_ID}${NC}"
echo ""
echo "2. Scroll down to 'Private keys' section"
echo "3. Click 'Generate a private key'"
echo "4. Download the .pem file (you can only download once!)"
echo "5. Save it to a secure location (e.g., ~/.github-arc/private-key.pem)"
echo ""
prompt "Press Enter when you have downloaded the private key..."
read -r

log_info "Step 2: Install App and Get Installation ID"
echo ""
echo "1. On the app page, click 'Install App' (in sidebar or top)"
echo "2. Select your organization: ${ORG_NAME}"
echo "3. Choose 'All repositories' (recommended for ARC)"
echo "4. Click 'Install'"
echo "5. After installation, note the Installation ID from the URL:"
echo "   URL will be: /installations/<INSTALLATION_ID>"
echo ""
echo "   Or check the page - Installation ID is shown on the installation page"
echo ""
prompt "Enter the Installation ID:"
read -r INSTALLATION_ID

if [[ -z "$INSTALLATION_ID" ]]; then
    echo "Installation ID cannot be empty. Exiting."
    exit 1
fi

log_info "Step 3: Private Key Path"
echo ""
prompt "Enter the full path to your private key file (.pem):"
read -r PRIVATE_KEY_PATH

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    echo "Private key file not found: $PRIVATE_KEY_PATH"
    exit 1
fi

log_info "Step 4: Select Clusters"
echo ""
prompt "Which cluster(s) should we set up? (1=nprd-apps, 2=prd-apps, 3=both):"
read -r CLUSTER_CHOICE

case "$CLUSTER_CHOICE" in
    1)
        CLUSTERS=("nprd-apps")
        ;;
    2)
        CLUSTERS=("prd-apps")
        ;;
    3)
        CLUSTERS=("nprd-apps" "prd-apps")
        ;;
    *)
        echo "Invalid choice. Using both clusters."
        CLUSTERS=("nprd-apps" "prd-apps")
        ;;
esac

prompt "Enter namespace for runner secret (default: managed-cicd):"
read -r RUNNER_NAMESPACE
RUNNER_NAMESPACE="${RUNNER_NAMESPACE:-managed-cicd}"

echo ""
echo "=================================================="
echo "  Creating Kubernetes Secrets"
echo "=================================================="
echo ""

for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    log_info "Setting up secrets for cluster: $CLUSTER"
    echo ""
    
    "$SCRIPT_DIR/create-github-app-secrets.sh" \
        -c "$CLUSTER" \
        -i "$APP_ID" \
        -n "$INSTALLATION_ID" \
        -k "$PRIVATE_KEY_PATH" \
        || {
            log_warning "Failed to create secrets for $CLUSTER"
            continue
        }
done

echo ""
echo "=================================================="
echo "  Setup Complete!"
echo "=================================================="
echo ""

log_success "GitHub App secrets have been created!"
echo ""
echo "Summary:"
echo "  • App ID: ${APP_ID}"
echo "  • Installation ID: ${INSTALLATION_ID}"
echo "  • Clusters: ${CLUSTERS[*]}"
echo "  • Runner Namespace: ${RUNNER_NAMESPACE}"
echo ""
echo "Next steps:"
echo "  1. Verify your AutoscalingRunnerSet references the secret:"
echo "     spec.githubConfigSecret: github-app-secret"
echo ""
echo "  2. Check controller pods:"
for CLUSTER in "${CLUSTERS[@]}"; do
    echo "     kubectl --kubeconfig ~/.kube/${CLUSTER}.yaml get pods -n actions-runner-system"
done
echo ""
echo "  3. Check controller logs:"
for CLUSTER in "${CLUSTERS[@]}"; do
    echo "     kubectl --kubeconfig ~/.kube/${CLUSTER}.yaml logs -n actions-runner-system \\"
    echo "       -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50"
done
echo ""
