#!/usr/bin/env bash
set -euo pipefail

# Get GitHub App Installation ID using JWT authentication
# Based on: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app

# Parameters with no defaults - user must provide
APP_ID="${1:-}"
CLIENT_ID="${2:-}"
PRIVATE_KEY_PATH="${3:-}"
ORG_NAME="${4:-}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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

# Validate required parameters
if [[ -z "$APP_ID" ]]; then
    log_error "App ID is required"
    echo "Usage: $0 <app_id> [client_id] [private_key_path] [org_name]" >&2
    exit 1
fi

if [[ -z "$CLIENT_ID" ]]; then
    log_error "Client ID is required"
    echo "Usage: $0 <app_id> <client_id> [private_key_path] [org_name]" >&2
    exit 1
fi

if [[ -z "$PRIVATE_KEY_PATH" ]]; then
    log_error "Private key path is required"
    echo "Usage: $0 <app_id> <client_id> <private_key_path> [org_name]" >&2
    exit 1
fi

if [[ -z "$ORG_NAME" ]]; then
    log_error "Organization name is required"
    echo "Usage: $0 <app_id> <client_id> <private_key_path> <org_name>" >&2
    exit 1
fi

# Check if private key exists
if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
    log_error "Private key file not found: $PRIVATE_KEY_PATH"
    exit 1
fi

log_info "Generating JWT token for GitHub App..."
log_info "App ID: $APP_ID"
log_info "Client ID: $CLIENT_ID"
log_info "Private Key: $PRIVATE_KEY_PATH"

# Generate JWT using bash/openssl (no dependencies needed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_JWT_SCRIPT="${SCRIPT_DIR}/generate-jwt.sh"

if [[ ! -f "$GENERATE_JWT_SCRIPT" ]]; then
    log_error "JWT generator script not found: $GENERATE_JWT_SCRIPT"
    exit 1
fi

JWT=$("$GENERATE_JWT_SCRIPT" "$CLIENT_ID" "$PRIVATE_KEY_PATH" 2>/dev/null)

if [[ -z "$JWT" ]]; then
    log_error "Failed to generate JWT token"
    exit 1
fi

log_success "JWT token generated"

# Use JWT to get app information
log_info "Getting app information..."
APP_INFO=$(gh api "app" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${JWT}" \
    --header "X-GitHub-Api-Version: 2022-11-28" 2>/dev/null || echo "")

if [[ -z "$APP_INFO" ]]; then
    log_error "Failed to authenticate with GitHub App"
    log_info "Make sure the app exists and the private key is correct"
    exit 1
fi

log_success "Authenticated with GitHub App"

# Get installations for the app (using app/installations endpoint)
log_info "Getting installations for this app..."
INSTALLATIONS=$(gh api "app/installations" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${JWT}" \
    --header "X-GitHub-Api-Version: 2022-11-28" 2>/dev/null || echo "[]")

if [[ "$INSTALLATIONS" == "[]" || -z "$INSTALLATIONS" ]]; then
    log_warning "No installations found for this app"
    echo ""
    log_info "The app may not be installed yet. To install it:"
    echo "  1. Go to: https://github.com/organizations/${ORG_NAME}/settings/apps/${APP_ID}"
    echo "  2. Click 'Install App'"
    echo "  3. Select your organization: ${ORG_NAME}"
    echo "  4. Choose 'All repositories' (recommended)"
    echo "  5. Click 'Install'"
    echo ""
    log_info "After installation, run this script again to get the Installation ID"
    exit 0
fi

# Parse installation ID - check for app_id match or get the first one
INSTALLATION_ID=$(echo "$INSTALLATIONS" | jq -r ".[] | select(.app_id == ${APP_ID}) | .id" 2>/dev/null || echo "")

# If no match found by app_id, try to get the first installation
if [[ -z "$INSTALLATION_ID" || "$INSTALLATION_ID" == "null" ]]; then
    INSTALLATION_ID=$(echo "$INSTALLATIONS" | jq -r ".[0].id" 2>/dev/null || echo "")
fi

if [[ -z "$INSTALLATION_ID" || "$INSTALLATION_ID" == "null" ]]; then
    log_warning "Could not find installation for App ID ${APP_ID}"
    echo ""
    log_info "Available installations:"
    echo "$INSTALLATIONS" | jq -r '.[] | "  - Installation ID: \(.id), App ID: \(.app_id), App Slug: \(.app_slug)"' 2>/dev/null || echo "  (unable to parse)"
    echo ""
    log_info "Check installations manually:"
    echo "  https://github.com/organizations/${ORG_NAME}/settings/installations"
    exit 1
fi

# Get installation details
INSTALLATION_INFO=$(gh api "app/installations/${INSTALLATION_ID}" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${JWT}" \
    --header "X-GitHub-Api-Version: 2022-11-28" 2>/dev/null || echo "")

if [[ -n "$INSTALLATION_INFO" ]]; then
    echo ""
    log_success "Found Installation!"
    echo ""
    echo "Installation Details:"
    echo "$INSTALLATION_INFO" | jq -r '
        "  Installation ID: \(.id)",
        "  Account: \(.account.login)",
        "  Repository Selection: \(.repository_selection)",
        "  Permissions:",
        (.permissions | to_entries | .[] | "    \(.key): \(.value)")
    ' 2>/dev/null || echo "  Installation ID: ${INSTALLATION_ID}"
else
    echo ""
    log_success "Installation ID: ${INSTALLATION_ID}"
fi

echo ""
echo "=================================================="
echo "  Installation ID: ${INSTALLATION_ID}"
echo "=================================================="
echo ""
echo "You can now create Kubernetes secrets using:"
echo ""
echo "  ./scripts/create-github-app-secrets.sh \\"
echo "    -c nprd-apps \\"
echo "    -i ${APP_ID} \\"
echo "    -n ${INSTALLATION_ID} \\"
echo "    -k ${PRIVATE_KEY_PATH}"
echo ""
