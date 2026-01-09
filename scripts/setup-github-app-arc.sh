#!/usr/bin/env bash
set -euo pipefail

# Interactive script to guide GitHub App creation and secret setup for ARC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ORG_NAME="${GITHUB_ORG:-DataKnifeAI}"

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

prompt() {
    echo -e "${CYAN}?${NC} $1"
}

echo "=================================================="
echo "  GitHub Actions Runner Controller (ARC)"
echo "  GitHub App Setup Guide"
echo "=================================================="
echo ""

log_info "This script will guide you through creating a GitHub App and setting up Kubernetes secrets."
echo ""

# Step 1: Check if app already exists
prompt "Do you already have a GitHub App created? (y/n)"
read -r HAS_APP

if [[ "$HAS_APP" != "y" && "$HAS_APP" != "Y" ]]; then
    echo ""
    log_info "Step 1: Create GitHub App via Web Interface"
    echo ""
    
    # Show name suggestions
    if [[ -f "$SCRIPT_DIR/suggest-github-app-name.sh" ]]; then
        "$SCRIPT_DIR/suggest-github-app-name.sh" "$ORG_NAME"
    fi
    
    echo "Open this URL in your browser to create the app:"
    echo -e "${CYAN}https://github.com/organizations/${ORG_NAME}/settings/apps/new${NC}"
    echo ""
    echo "Or check existing apps first:"
    echo -e "${CYAN}https://github.com/organizations/${ORG_NAME}/settings/apps${NC}"
    echo ""
    echo "Configure the app with these settings:"
    log_warning "Important: App names must be unique across ALL GitHub. Use the suggestions above if name is taken."
    echo ""
    echo "  • Homepage URL: https://github.com/${ORG_NAME}"
    echo "  • Webhook: Leave unchecked"
    echo ""
    echo "  Repository Permissions:"
    echo "    • Actions: Read & Write"
    echo "    • Metadata: Read-only"
    echo ""
    echo "  Organization Permissions:"
    echo "    • Self-hosted runners: Read & Write"
    echo ""
    echo "  • Where can this GitHub App be installed?: Only on this account"
    echo ""
    log_info "To check existing apps: https://github.com/organizations/${ORG_NAME}/settings/apps"
    echo ""
    echo "Press Enter when you've created the app (or if name was taken, choose another name and try again)..."
    read -r
    
    echo ""
    log_info "Step 2: Get App ID and Generate Private Key"
    echo ""
    echo "After creating the app:"
    echo "  1. Note the App ID (visible on the app page, under the app name)"
    echo "  2. Scroll down to 'Private keys'"
    echo "  3. Click 'Generate a private key'"
    echo "  4. Save the downloaded .pem file to a secure location"
    echo ""
    log_warning "If you see 'Name already taken' error:"
    echo "  - Try a different name with date suffix: arc-runner-controller-$(date +%Y%m%d)"
    echo "  - Or add environment: arc-runner-controller-nprd"
    echo "  - Or check existing apps: https://github.com/organizations/${ORG_NAME}/settings/apps"
    echo ""
    echo "Press Enter when you have the App ID and private key downloaded..."
    read -r
    
    echo ""
    log_info "Step 3: Install the GitHub App"
    echo ""
    echo "1. On the app page, click 'Install App' (in the sidebar or top)"
    echo "2. Select your organization: ${ORG_NAME}"
    echo "3. Choose installation permissions (All repositories recommended for ARC)"
    echo "4. Click 'Install'"
    echo "5. Note the Installation ID from the URL: /installations/<INSTALLATION_ID>"
    echo ""
    echo "Press Enter when you've installed the app..."
    read -r
fi

echo ""
echo "=================================================="
echo "  Collect App Information"
echo "=================================================="
echo ""

# Collect App ID
prompt "Enter GitHub App ID:"
read -r APP_ID
if [[ -z "$APP_ID" ]]; then
    log_warning "App ID cannot be empty. Exiting."
    exit 1
fi

# Collect Installation ID
prompt "Enter GitHub App Installation ID:"
read -r INSTALLATION_ID
if [[ -z "$INSTALLATION_ID" ]]; then
    log_warning "Installation ID cannot be empty. Exiting."
    exit 1
fi

# Collect private key path
prompt "Enter path to GitHub App private key (.pem file):"
read -r PRIVATE_KEY_PATH
if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    log_warning "Private key file not found: $PRIVATE_KEY_PATH"
    exit 1
fi

# Collect cluster
echo ""
prompt "Which cluster(s) should we set up secrets for?"
echo "  1) nprd-apps only"
echo "  2) prd-apps only"
echo "  3) Both clusters"
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
        log_warning "Invalid choice. Exiting."
        exit 1
        ;;
esac

# Collect namespace for runner secret
prompt "Enter namespace for runner secret (default: managed-cicd):"
read -r RUNNER_NAMESPACE
RUNNER_NAMESPACE="${RUNNER_NAMESPACE:-managed-cicd}"

echo ""
echo "=================================================="
echo "  Create Kubernetes Secrets"
echo "=================================================="
echo ""

# Verify app access using gh CLI
log_info "Verifying GitHub App access..."
if gh api "app/installations/${INSTALLATION_ID}" &>/dev/null; then
    log_success "GitHub App installation found"
else
    log_warning "Could not verify installation access via API (this is OK if you don't have admin access)"
fi

# Create secrets for each cluster
for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    log_info "Setting up secrets for cluster: $CLUSTER"
    echo ""
    
    # Call the secret creation script
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

log_success "GitHub App secrets have been created for: ${CLUSTERS[*]}"
echo ""
echo "Next steps:"
echo "  1. Ensure your AutoscalingRunnerSet resource references the secret:"
echo "     spec.githubConfigSecret: github-app-secret"
echo ""
echo "  2. Verify controller pods are running:"
for CLUSTER in "${CLUSTERS[@]}"; do
    echo "     kubectl --kubeconfig ~/.kube/${CLUSTER}.yaml get pods -n actions-runner-system"
done
echo ""
echo "  3. Check controller logs for any errors:"
for CLUSTER in "${CLUSTERS[@]}"; do
    echo "     kubectl --kubeconfig ~/.kube/${CLUSTER}.yaml logs -n actions-runner-system \\"
    echo "       -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50"
done
echo ""
echo "  4. Once the AutoscalingRunnerSet is deployed, check runner status:"
echo "     kubectl get autoscalingrunnersets -n ${RUNNER_NAMESPACE}"
echo ""
