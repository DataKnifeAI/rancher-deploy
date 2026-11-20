#!/usr/bin/env bash
# Install DataKnife app operators (CRD + RBAC + controller) from rendered manifests.
# Does NOT create game/Stoat instance CRs.
#
# Usage (from repo root, after terraform renders or with TEMPLATES_DIR):
#   OPERATOR_IMAGE_STOAT=... OPERATOR_IMAGE_SATISFACTORY=... \
#   ./scripts/install-dataknife-operators.sh prd-apps
#
# Env:
#   KUBECONFIG
#   TEMPLATES_DIR          default: terraform/templates/operators
#   IMAGE_PULL_SECRET      optional secret name to copy into each operator ns
#   IMAGE_PULL_SECRET_FILE optional path to secret YAML (namespace rewritten)
#   OPERATORS              space-separated list (default: all known)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER="${1:-prd-apps}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$REPO_ROOT/terraform/templates/operators}"

if [ -z "${KUBECONFIG:-}" ]; then
  export KUBECONFIG="$HOME/.kube/${CLUSTER}.yaml"
fi

declare -A DEFAULT_IMAGES=(
  [stoat-operator]="harbor.dataknife.net/library/stoat-operator:9bdea64"
  [satisfactory-operator]="harbor.dataknife.net/library/satisfactory-operator:v0.1.0"
  [terraria-operator]="harbor.dataknife.net/library/terraria-operator:phase3-parity"
  [bedrock-operator]="harbor.dataknife.net/library/bedrock-operator:joinfix-20261117084844"
  [dragonwilds-operator]="harbor.dataknife.net/library/dragonwilds-operator:v0.2.3"
)

OPERATORS="${OPERATORS:-stoat-operator satisfactory-operator terraria-operator bedrock-operator dragonwilds-operator}"

command -v kubectl >/dev/null || { echo -e "${RED}kubectl not found${NC}"; exit 1; }
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Cannot access cluster (KUBECONFIG=${KUBECONFIG})${NC}"
  exit 1
fi

ensure_pull_secret() {
  local ns="$1"
  local name="${IMAGE_PULL_SECRET:-}"
  local file="${IMAGE_PULL_SECRET_FILE:-}"
  [ -z "$name" ] && return 0
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if kubectl get secret "$name" -n "$ns" &>/dev/null; then
    echo "  ✓ pull secret ${name} in ${ns}"
    return 0
  fi
  if [ -n "$file" ] && [ -f "$file" ]; then
    if command -v jq >/dev/null; then
      jq --arg ns "$ns" --arg name "$name" \
        'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = $ns | .metadata.name = $name' \
        "$file" | kubectl apply -f -
    else
      echo -e "${YELLOW}jq missing; apply pull secret manually into ${ns}${NC}"
    fi
  else
    echo -e "${YELLOW}WARNING: pull secret ${name} missing in ${ns}${NC}"
  fi
}

for op in $OPERATORS; do
  tpl="${TEMPLATES_DIR}/${op}.yaml.tpl"
  ns="${op}-system"
  # Allow env override: OPERATOR_IMAGE_STOAT_OPERATOR or OPERATOR_IMAGE_stoat-operator
  env_key=$(echo "OPERATOR_IMAGE_${op}" | tr 'a-z-' 'A-Z_')
  image="${!env_key:-${DEFAULT_IMAGES[$op]:-}}"
  if [ -z "$image" ]; then
    echo -e "${RED}No image for ${op}; set ${env_key}${NC}"
    exit 1
  fi
  if [ ! -f "$tpl" ]; then
    echo -e "${RED}Missing template ${tpl}${NC}"
    exit 1
  fi

  echo -e "${GREEN}→ ${op} (${image})${NC}"
  ensure_pull_secret "$ns"

  MANIFEST=$(mktemp)
  pull_secret="${IMAGE_PULL_SECRET:-harbor-registry-secret}"
  # Templates use ${operator_image} / ${image_pull_secret} for terraform templatefile.
  sed -e "s|\${operator_image}|${image}|g" \
      -e "s|\${image_pull_secret}|${pull_secret}|g" \
      "$tpl" > "$MANIFEST"
  kubectl apply --server-side --force-conflicts -f "$MANIFEST"
  rm -f "$MANIFEST"

  kubectl -n "$ns" rollout status "deployment/${op}-controller-manager" --timeout=5m || true
  kubectl -n "$ns" get deploy,pods
done

echo -e "${GREEN}DataKnife operators applied on ${CLUSTER}${NC}"
