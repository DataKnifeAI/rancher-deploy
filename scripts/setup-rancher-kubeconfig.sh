#!/bin/bash

# Build a kubeconfig whose users authenticate through the Rancher CLI
# (`rancher token` exec credential plugin) instead of embedded tokens.
# kubectl asks Rancher for a token on demand and the CLI caches it in
# ~/.rancher/cli2.json, so kubeconfigs never need re-downloading when tokens expire.
#
# Usage: ./scripts/setup-rancher-kubeconfig.sh [options]
#   --server HOST          Rancher hostname (default: rancher_hostname in terraform/terraform.tfvars)
#   --output FILE          Kubeconfig to write (default: ~/.kube/rancher.yaml)
#   --merge                Merge into ~/.kube/config, replacing same-named entries (backup kept)
#   --disable-ui-tokens    Set Rancher's kubeconfig-generate-token=false so UI downloads use the CLI too
#   --install-cli          Install the rancher CLI into ~/.local/bin if missing
#   --auth-provider NAME   Rancher auth provider for login, e.g. keyCloakProvider (SAML, prints a
#                          login link) or localProvider (password). Required once more than one
#                          provider is enabled, otherwise `rancher token` asks interactively.
#   --break-glass          Also write <cluster>-local contexts that always use localProvider
#
# API access (used only to look up your user id and the cluster list) comes from, in order:
#   $RANCHER_TOKEN, rancher_api_token in terraform/terraform.tfvars, an existing token in
#   ~/.kube/config for a context that points at the Rancher server, or the rancher CLI cache.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"

RANCHER_HOST=""
OUTPUT="${HOME}/.kube/rancher.yaml"
MERGE=0
DISABLE_UI_TOKENS=0
INSTALL_CLI=0
AUTH_PROVIDER=""
BREAK_GLASS=0

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server) RANCHER_HOST="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --merge) MERGE=1; shift ;;
    --disable-ui-tokens) DISABLE_UI_TOKENS=1; shift ;;
    --install-cli) INSTALL_CLI=1; shift ;;
    --auth-provider) AUTH_PROVIDER="$2"; shift 2 ;;
    --break-glass) BREAK_GLASS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage; exit 1 ;;
  esac
done

tfvar() {
  [ -f "$TFVARS" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFVARS" | head -n1
}

for tool in curl jq kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo -e "${RED}Error: $tool is required${NC}" >&2; exit 1; }
done

RANCHER_HOST="${RANCHER_HOST:-$(tfvar rancher_hostname)}"
RANCHER_HOST="${RANCHER_HOST#https://}"
RANCHER_HOST="${RANCHER_HOST%%/*}"
if [ -z "$RANCHER_HOST" ]; then
  echo -e "${RED}Error: Rancher hostname not set (use --server or rancher_hostname in terraform.tfvars)${NC}" >&2
  exit 1
fi
RANCHER_URL="https://${RANCHER_HOST}"

# --- Rancher CLI -------------------------------------------------------------

install_rancher_cli() {
  local loc ver tmp bin
  loc=$(curl -sI -A "Mozilla/5.0" https://github.com/rancher/cli/releases/latest | grep -i '^location:' | awk '{print $2}' | tr -d '\r' | head -n1)
  ver="${loc##*/}"
  [ -n "$ver" ] || { echo -e "${RED}Error: could not resolve latest rancher CLI release${NC}" >&2; exit 1; }
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/rancher/cli/releases/download/${ver}/rancher-linux-amd64-${ver}.tar.gz" -o "${tmp}/rancher.tgz"
  tar -xzf "${tmp}/rancher.tgz" -C "$tmp"
  bin=$(find "$tmp" -name rancher -type f | head -n1)
  mkdir -p "${HOME}/.local/bin"
  install -m 0755 "$bin" "${HOME}/.local/bin/rancher"
  rm -rf "$tmp"
  echo -e "${GREEN}✓ Installed rancher CLI ${ver} to ~/.local/bin/rancher${NC}"
}

if ! command -v rancher >/dev/null 2>&1; then
  if [ "$INSTALL_CLI" -eq 1 ]; then
    install_rancher_cli
  else
    echo -e "${YELLOW}⚠ rancher CLI not found in PATH; kubectl will fail until it is installed (re-run with --install-cli)${NC}"
  fi
fi

# --- API token ---------------------------------------------------------------

api() {
  curl -fsS -H "Authorization: Bearer ${API_TOKEN}" "$@"
}

candidate_tokens() {
  [ -n "${RANCHER_TOKEN:-}" ] && echo "$RANCHER_TOKEN"
  tfvar rancher_api_token
  kubectl config view --raw -o json 2>/dev/null | jq -r --arg url "$RANCHER_URL" '
    . as $kc
    | [$kc.clusters[]? | select(.cluster.server | startswith($url)) | .name] as $names
    | $kc.contexts[]? | select(.context.cluster as $c | $names | index($c))
    | .context.user as $u
    | $kc.users[]? | select(.name == $u) | .user.token // empty'
  [ -f "${HOME}/.rancher/cli2.json" ] && jq -r '.Servers[]?.KubeCredentials[]?.status.token // empty' "${HOME}/.rancher/cli2.json"
  return 0
}

API_TOKEN=""
USER_ID=""
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  API_TOKEN="$tok"
  if USER_ID=$(api "${RANCHER_URL}/v3/users?me=true" 2>/dev/null | jq -r '.data[0].id // empty') && [ -n "$USER_ID" ]; then
    break
  fi
  API_TOKEN=""
done < <(candidate_tokens | awk '!seen[$0]++')

if [ -z "$API_TOKEN" ]; then
  echo -e "${RED}Error: no working Rancher API token found${NC}" >&2
  echo "Set RANCHER_TOKEN (Rancher UI → Account & API Keys) and re-run." >&2
  exit 1
fi
echo -e "${GREEN}✓ Authenticated to ${RANCHER_URL} as ${USER_ID}${NC}"

# --- Optional: make UI kubeconfig downloads exec-based too ------------------

if [ "$DISABLE_UI_TOKENS" -eq 1 ]; then
  api -X PUT -H "Content-Type: application/json" -d '{"value":"false"}' \
    "${RANCHER_URL}/v3/settings/kubeconfig-generate-token" >/dev/null
  echo -e "${GREEN}✓ Set kubeconfig-generate-token=false${NC}"
fi

# --- Build kubeconfig --------------------------------------------------------

CA_CERTS=$(api "${RANCHER_URL}/v3/settings/cacerts" | jq -r '.value // empty')
CA_FILE=""
if [ -n "$CA_CERTS" ]; then
  CA_FILE="${HOME}/.kube/rancher-ca.pem"
  mkdir -p "${HOME}/.kube"
  printf '%s\n' "$CA_CERTS" > "$CA_FILE"
fi

CLUSTERS=$(api "${RANCHER_URL}/v3/clusters" | jq -r '.data[] | select(.state == "active") | "\(.id) \(.name)"')
if [ -z "$CLUSTERS" ]; then
  echo -e "${RED}Error: no active clusters visible to ${USER_ID}${NC}" >&2
  exit 1
fi

EXISTING_JSON=$(kubectl config view -o json 2>/dev/null || echo '{}')

mkdir -p "$(dirname "$OUTPUT")"
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

EXEC_ARGS=(--exec-arg=token "--exec-arg=--server=${RANCHER_HOST}" "--exec-arg=--user=${USER_ID}")
[ -n "$CA_FILE" ] && EXEC_ARGS+=("--exec-arg=--cacerts=${CA_FILE}")

kc() { kubectl --kubeconfig "$TMP_OUT" config "$@" >/dev/null; }

# add_context <context/user name> <cluster name> <auth provider or empty>
add_context() {
  local ctx="$1" cluster="$2" provider="$3" ns
  local args=("${EXEC_ARGS[@]}")
  [ -n "$provider" ] && args+=("--exec-arg=--auth-provider=${provider}")
  kc set-credentials "$ctx" \
    --exec-api-version=client.authentication.k8s.io/v1beta1 \
    --exec-command=rancher \
    --exec-interactive-mode=IfAvailable \
    "${args[@]}"
  ns=$(jq -r --arg n "$ctx" '.contexts[]? | select(.name == $n) | .context.namespace // empty' <<<"$EXISTING_JSON")
  kc set-context "$ctx" --cluster="$cluster" --user="$ctx" ${ns:+--namespace="$ns"}
  echo "  + ${ctx}${provider:+ [${provider}]}${ns:+ namespace=${ns}}"
}

while read -r id name; do
  kc set-cluster "$name" --server="${RANCHER_URL}/k8s/clusters/${id}"
  if [ -n "$CA_FILE" ]; then
    kc set-cluster "$name" --certificate-authority="$CA_FILE" --embed-certs=true
  fi
  add_context "$name" "$name" "$AUTH_PROVIDER"
  if [ "$BREAK_GLASS" -eq 1 ]; then
    add_context "${name}-local" "$name" localProvider
  fi
done <<<"$CLUSTERS"

install -m 0600 "$TMP_OUT" "$OUTPUT"
echo -e "${GREEN}✓ Wrote ${OUTPUT}${NC}"

# --- Optional merge ----------------------------------------------------------

if [ "$MERGE" -eq 1 ]; then
  MAIN="${HOME}/.kube/config"
  if [ -f "$MAIN" ]; then
    BACKUP="${MAIN}.bak-$(date +%Y%m%d%H%M%S)"
    cp -p "$MAIN" "$BACKUP"
    echo "  Backup: ${BACKUP}"
  fi
  MERGED=$(mktemp)
  # First file wins on name collisions, so the exec-based entries replace token-based ones.
  KUBECONFIG="${OUTPUT}:${MAIN}" kubectl config view --flatten > "$MERGED"
  install -m 0600 "$MERGED" "$MAIN"
  rm -f "$MERGED"
  echo -e "${GREEN}✓ Merged into ${MAIN}${NC}"
fi

echo ""
echo -e "${YELLOW}Next:${NC} run any kubectl command (e.g. kubectl --context <cluster> get nodes)."
echo "  The first call asks you to log in (a link for SAML providers, a password prompt for local"
echo "  users); the token is cached in ~/.rancher/cli2.json"
echo "  and shared by all clusters. Clear it with: rancher token delete all"
