#!/usr/bin/env bash
set -euo pipefail

# List GitHub Apps for an organization using gh CLI

ORG_NAME="${1:-${GITHUB_ORG:-DataKnifeAI}}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

echo "=================================================="
echo "  GitHub Apps for Organization: ${ORG_NAME}"
echo "=================================================="
echo ""

log_info "Note: GitHub Apps can only be listed via the web interface."
echo ""
echo "To view your GitHub Apps:"
echo "  https://github.com/organizations/${ORG_NAME}/settings/apps"
echo ""
echo "Or for your personal account:"
echo "  https://github.com/settings/apps"
echo ""

# Try to check if we can list installations (requires admin access)
log_info "Checking GitHub App installations (if you have admin access)..."
echo ""

if gh api "orgs/${ORG_NAME}/installations" --jq '.[] | {id: .id, app_slug: .app_slug}' 2>/dev/null; then
    echo ""
    log_info "To get detailed information about an installation:"
    echo "  gh api 'orgs/${ORG_NAME}/installations' | jq"
else
    log_info "Could not list installations via API (requires organization admin permissions)"
    echo ""
    log_info "You can still create apps via the web interface:"
    echo "  https://github.com/organizations/${ORG_NAME}/settings/apps/new"
fi

echo ""
