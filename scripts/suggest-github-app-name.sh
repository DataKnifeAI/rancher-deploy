#!/usr/bin/env bash
# Suggest unique GitHub App names to avoid conflicts

ORG_NAME="${1:-${GITHUB_ORG:-DataKnifeAI}}"
ENV="${2:-}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================================="
echo "  Suggested GitHub App Names"
echo "=================================================="
echo ""

echo -e "${CYAN}GitHub App names must be unique across ALL GitHub accounts.${NC}"
echo -e "${YELLOW}If a name is taken, try the next suggestion.${NC}"
echo ""

ORG_LOWER=$(echo "$ORG_NAME" | tr '[:upper:]' '[:lower:]')
DATE_SUFFIX=$(date +%Y%m%d)
DATE_SHORT=$(date +%m%d)

echo "Suggested names (in order of preference):"
echo ""
echo -e "${GREEN}1.${NC} arc-runner-controller-${ORG_LOWER}${ENV:+-$ENV}"
echo -e "   → Most descriptive, includes organization"
echo ""
echo -e "${GREEN}2.${NC} arc-runner-controller-${ORG_LOWER}-${DATE_SUFFIX}"
echo -e "   → Includes date to ensure uniqueness"
echo ""
echo -e "${GREEN}3.${NC} arc-runner-controller-${ORG_LOWER}-${DATE_SHORT}${ENV:+-$ENV}"
echo -e "   → Shorter date format"
echo ""
echo -e "${GREEN}4.${NC} ${ORG_LOWER}-arc-runner-controller${ENV:+-$ENV}"
echo -e "   → Organization-first format"
echo ""
echo -e "${GREEN}5.${NC} arc-runner-${ORG_LOWER}${ENV:+-$ENV}"
echo -e "   → Shorter format"
echo ""

if [[ -n "$ENV" ]]; then
    echo "Environment-specific suggestions:"
    echo -e "${GREEN}6.${NC} arc-runner-controller-${ENV}-${ORG_LOWER}"
    echo -e "${GREEN}7.${NC} ${ORG_LOWER}-arc-${ENV}"
    echo ""
fi

echo "Tips:"
echo "  • Try names in order (1-7)"
echo "  • If all are taken, add more unique suffixes:"
echo "    - Your username: arc-runner-controller-${ORG_LOWER}-$(whoami 2>/dev/null || echo 'yourname')"
echo "    - Random suffix: arc-runner-controller-${ORG_LOWER}-$(openssl rand -hex 4 2>/dev/null || echo 'abcd1234')"
echo ""
echo "Check existing apps:"
echo "  https://github.com/organizations/${ORG_NAME}/settings/apps"
echo ""
