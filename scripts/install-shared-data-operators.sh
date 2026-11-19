#!/usr/bin/env bash
# Install cluster-scoped data-plane operators used by Stoat HA (and reusable by others):
#   - Percona Operator for MongoDB (psmdb) 1.23.x → percona-system
#   - OpsTree redis-operator 0.27.x → redis-operator
#   - RabbitMQ Cluster Operator 2.23.x → rabbitmq-system
#
# Usage:
#   ./scripts/install-shared-data-operators.sh [prd-apps|nprd-apps|poc-apps]
#
# Optional env:
#   PSMDB_OPERATOR_CHART_VERSION (default 1.23.2)
#   PSMDB_OPERATOR_CRDS_VERSION  (default 1.23.1)
#   REDIS_OPERATOR_CHART_VERSION (default 0.27.0)
#   RABBITMQ_CLUSTER_OPERATOR_VERSION (default 2.23.3)
#   KUBECONFIG (overrides default ~/.kube/<cluster>.yaml)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CLUSTER="${1:-prd-apps}"
PSMDB_OPERATOR_CHART_VERSION="${PSMDB_OPERATOR_CHART_VERSION:-1.23.2}"
PSMDB_OPERATOR_CRDS_VERSION="${PSMDB_OPERATOR_CRDS_VERSION:-1.23.1}"
REDIS_OPERATOR_CHART_VERSION="${REDIS_OPERATOR_CHART_VERSION:-0.27.0}"
RABBITMQ_CLUSTER_OPERATOR_VERSION="${RABBITMQ_CLUSTER_OPERATOR_VERSION:-2.23.3}"

if [ -z "${KUBECONFIG:-}" ]; then
  export KUBECONFIG="$HOME/.kube/${CLUSTER}.yaml"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Shared data operators → ${CLUSTER}${NC}"
echo -e "${GREEN}========================================${NC}"

command -v kubectl >/dev/null || { echo -e "${RED}kubectl not found${NC}"; exit 1; }
command -v helm >/dev/null || { echo -e "${RED}helm not found${NC}"; exit 1; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Cannot access cluster (KUBECONFIG=${KUBECONFIG})${NC}"
  exit 1
fi
echo "✓ cluster access (${KUBECONFIG})"

# --- Percona PSMDB ---
echo -e "${YELLOW}Percona psmdb-operator ${PSMDB_OPERATOR_CHART_VERSION}...${NC}"
helm repo add percona https://percona.github.io/percona-helm-charts/ >/dev/null 2>&1 || true
helm repo update percona >/dev/null
kubectl create namespace percona-system --dry-run=client -o yaml | kubectl apply -f -
if ! helm status psmdb-operator-crds -n percona-system &>/dev/null; then
  helm install psmdb-operator-crds percona/psmdb-operator-crds \
    --namespace percona-system \
    --version "${PSMDB_OPERATOR_CRDS_VERSION}" \
    --wait --timeout 5m
else
  helm upgrade psmdb-operator-crds percona/psmdb-operator-crds \
    --namespace percona-system \
    --version "${PSMDB_OPERATOR_CRDS_VERSION}" \
    --wait --timeout 5m
fi
if ! helm status psmdb-operator -n percona-system &>/dev/null; then
  helm install psmdb-operator percona/psmdb-operator \
    --namespace percona-system \
    --version "${PSMDB_OPERATOR_CHART_VERSION}" \
    --wait --timeout 10m
else
  helm upgrade psmdb-operator percona/psmdb-operator \
    --namespace percona-system \
    --version "${PSMDB_OPERATOR_CHART_VERSION}" \
    --wait --timeout 10m
fi
echo "✓ Percona psmdb-operator"

# --- OpsTree Redis ---
echo -e "${YELLOW}OpsTree redis-operator ${REDIS_OPERATOR_CHART_VERSION}...${NC}"
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update ot-helm >/dev/null
kubectl create namespace redis-operator --dry-run=client -o yaml | kubectl apply -f -
if ! helm status redis-operator -n redis-operator &>/dev/null; then
  helm install redis-operator ot-helm/redis-operator \
    --namespace redis-operator \
    --version "${REDIS_OPERATOR_CHART_VERSION}" \
    --wait --timeout 10m
else
  helm upgrade redis-operator ot-helm/redis-operator \
    --namespace redis-operator \
    --version "${REDIS_OPERATOR_CHART_VERSION}" \
    --wait --timeout 10m
fi
echo "✓ redis-operator"

# --- RabbitMQ Cluster Operator (official manifest; needs cert-manager) ---
echo -e "${YELLOW}RabbitMQ Cluster Operator ${RABBITMQ_CLUSTER_OPERATOR_VERSION}...${NC}"
if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
  echo -e "${RED}cert-manager CRDs missing; RabbitMQ Cluster Operator ≥2.20 needs cert-manager${NC}"
  exit 1
fi
RABBIT_URL="https://github.com/rabbitmq/cluster-operator/releases/download/v${RABBITMQ_CLUSTER_OPERATOR_VERSION}/cluster-operator.yml"
kubectl apply -f "${RABBIT_URL}"
kubectl -n rabbitmq-system rollout status deployment/rabbitmq-cluster-operator --timeout=5m || true
echo "✓ rabbitmq-cluster-operator"

echo ""
echo -e "${GREEN}Shared data operators ready on ${CLUSTER}${NC}"
kubectl get deploy -n percona-system,redis-operator,rabbitmq-system 2>/dev/null || true
kubectl get crd 2>/dev/null | grep -E 'psmdb.percona|redis.opstreelabs|rabbitmq.com' || true
