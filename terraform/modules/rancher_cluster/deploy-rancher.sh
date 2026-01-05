#!/bin/bash
set -e

# Script to deploy Rancher and cert-manager to a Kubernetes cluster
# Usage: deploy-rancher.sh <kubeconfig_path> <rancher_version> <rancher_hostname> <rancher_password> <cert_manager_version> [config_path]

KUBECONFIG="$1"
RANCHER_VERSION="$2"
RANCHER_HOSTNAME="$3"
RANCHER_PASSWORD="$4"
CERT_MANAGER_VERSION="$5"
CONFIG_PATH="${6:-.}"  # Default to current directory if not provided

export KUBECONFIG

# Ensure config directory exists
mkdir -p "$CONFIG_PATH"

echo "=========================================="
echo "Deploying Rancher to Kubernetes Cluster"
echo "=========================================="
echo "Kubeconfig: $KUBECONFIG"
echo "Rancher Version: $RANCHER_VERSION"
echo "Rancher Hostname: $RANCHER_HOSTNAME"
echo "Cert-Manager Version: $CERT_MANAGER_VERSION"
echo ""

# Verify cluster is accessible
echo "Verifying Kubernetes cluster access..."
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot access Kubernetes cluster. Check KUBECONFIG: $KUBECONFIG"
  exit 1
fi
kubectl cluster-info
echo ""

# Wait for cluster to be fully ready before installing Helm charts
echo "Checking cluster readiness before installing Helm charts..."
CLUSTER_READY=false
READY_RETRY=0
READY_MAX_RETRIES=60  # 5 minutes max (60 * 5 seconds)

while [ "$CLUSTER_READY" = false ] && [ $READY_RETRY -lt $READY_MAX_RETRIES ]; do
  READY_RETRY=$((READY_RETRY + 1))
  
  # Check API server is responsive
  if ! kubectl get nodes &>/dev/null; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - API server not ready, waiting..."
    sleep 5
    continue
  fi
  
  # Check that we have at least one node in Ready state
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  if [ "$READY_NODES" -eq 0 ]; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - No nodes in Ready state, waiting..."
    sleep 5
    continue
  fi
  
  # Check that core system pods are running (at least kube-system namespace exists and has pods)
  SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l || echo "0")
  if [ "$SYSTEM_PODS" -eq 0 ]; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - System pods not ready, waiting..."
    sleep 5
    continue
  fi
  
  # Check that CoreDNS is running (critical for cluster operations)
  if ! kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q "Running"; then
    echo "  Attempt $READY_RETRY/$READY_MAX_RETRIES - CoreDNS not ready, waiting..."
    sleep 5
    continue
  fi
  
  # All checks passed
  echo "✓ Cluster is ready ($READY_NODES node(s) ready, $SYSTEM_PODS system pod(s))"
  CLUSTER_READY=true
done

if [ "$CLUSTER_READY" = false ]; then
  echo "ERROR: Cluster not ready after $READY_MAX_RETRIES attempts (5 minutes)"
  echo "Current cluster status:"
  kubectl get nodes
  kubectl get pods -n kube-system
  exit 1
fi

# Add a short delay to ensure cluster is stable before proceeding
echo "Waiting 10 seconds for cluster to stabilize..."
sleep 10
echo "✓ Cluster is stable, proceeding with Helm installations"
echo ""

# Add helm repos
echo "Adding Helm repositories..."
helm repo add jetstack https://charts.jetstack.io --force-update || true
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update || true
helm repo update
echo "✓ Helm repositories updated"
echo ""

# Install cert-manager
echo "Installing cert-manager..."
kubectl create namespace cert-manager 2>/dev/null || true
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --version "$CERT_MANAGER_VERSION" \
  --wait \
  --timeout 10m \
  || {
    echo "ERROR: Failed to install cert-manager"
    exit 1
  }
echo "✓ cert-manager installed"
echo ""

# Wait for cert-manager to be ready
echo "Waiting for cert-manager deployment..."
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=5m
echo "✓ cert-manager is ready"
echo ""

# Install Rancher
echo "Installing Rancher..."
kubectl create namespace cattle-system 2>/dev/null || true
helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname="$RANCHER_HOSTNAME" \
  --set replicas=3 \
  --set bootstrapPassword="$RANCHER_PASSWORD" \
  --version "$RANCHER_VERSION" \
  --wait \
  --timeout 15m \
  || {
    echo "ERROR: Failed to install Rancher"
    exit 1
  }
echo "✓ Rancher installed"
echo ""

# Wait for Rancher to be ready
echo "Waiting for Rancher deployment..."
kubectl rollout status deployment/rancher -n cattle-system --timeout=10m
echo "✓ Rancher deployment is ready"
echo ""

# Wait for all Rancher pods to be actually running
echo "Waiting for all Rancher pods to be in Running state..."
POD_READY=false
POD_RETRY=0
POD_MAX_RETRIES=180

while [ "$POD_READY" = false ] && [ $POD_RETRY -lt $POD_MAX_RETRIES ]; do
  POD_RETRY=$((POD_RETRY + 1))
  
  # Count total Rancher pods and running Rancher pods
  TOTAL_PODS=$(kubectl get pods -n cattle-system -l app=rancher --no-headers 2>/dev/null | wc -l)
  RUNNING_PODS=$(kubectl get pods -n cattle-system -l app=rancher --no-headers 2>/dev/null | grep "Running" | wc -l)
  
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$TOTAL_PODS" -eq "$RUNNING_PODS" ]; then
    echo "✓ All Rancher pods are Running ($RUNNING_PODS/$TOTAL_PODS)"
    POD_READY=true
  else
    echo "  Attempt $POD_RETRY/$POD_MAX_RETRIES - Waiting... ($RUNNING_PODS/$TOTAL_PODS pods Running)"
    sleep 5
  fi
done

if [ "$POD_READY" = false ]; then
  echo "ERROR: Not all Rancher pods are running after $POD_MAX_RETRIES attempts (15 minutes)"
  echo "Current pod status:"
  kubectl get pods -n cattle-system -l app=rancher
  exit 1
fi
echo ""

# Display summary
echo "=========================================="
echo "✓ Deployment Complete!"
echo "=========================================="
echo ""
echo "Rancher URL: https://$RANCHER_HOSTNAME"
echo "Bootstrap Password: $RANCHER_PASSWORD"
echo ""
echo "Access with:"
echo "  Username: admin"
echo "  Password: $RANCHER_PASSWORD"
echo ""

# Get ingress info
echo "Ingress Information:"
kubectl get ingress -n cattle-system
echo ""

# Get Rancher pod status
echo "Rancher Pod Status:"
kubectl get pods -n cattle-system
echo ""

# Test Rancher URL accessibility
echo "Testing Rancher URL accessibility..."
RETRY_COUNT=0
MAX_RETRIES=60
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$RANCHER_HOSTNAME" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✓ Rancher is accessible at https://$RANCHER_HOSTNAME (HTTP $HTTP_CODE)"
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    echo "  Attempt $RETRY_COUNT/$MAX_RETRIES - Waiting for Rancher to be ready (HTTP $HTTP_CODE)..."
    sleep 10
  fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "WARNING: Rancher URL is not responding after $MAX_RETRIES attempts"
  echo "Please verify DNS resolution and firewall rules"
fi
echo ""

# ============================================================================# VERIFY RANCHER API IS ACCESSIBLE
# ============================================================================

echo "Verifying Rancher API accessibility..."
API_READY=false
API_RETRY_COUNT=0
API_MAX_RETRIES=30

while [ $API_RETRY_COUNT -lt $API_MAX_RETRIES ]; do
  # Test the auth API endpoint specifically
  API_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"username":"test","password":"test"}' \
    -w "\n%{http_code}" \
    -k "https://$RANCHER_HOSTNAME/v3-public/localProviders/local?action=login" 2>&1)
  
  # Extract HTTP code (last line)
  HTTP_CODE=$(echo "$API_RESPONSE" | tail -1)
  
  # 401 or 422 means API is responding (auth failure is expected with wrong creds)
  # 200 would also be fine
  if echo "$HTTP_CODE" | grep -q "^[24][0-9][0-9]$"; then
    echo "✓ Rancher API is accessible (HTTP $HTTP_CODE)"
    API_READY=true
    break
  fi
  
  API_RETRY_COUNT=$((API_RETRY_COUNT + 1))
  if [ $API_RETRY_COUNT -lt $API_MAX_RETRIES ]; then
    echo "  Attempt $API_RETRY_COUNT/$API_MAX_RETRIES - Waiting for API to be ready (HTTP $HTTP_CODE)..."
    sleep 2
  fi
done

if [ "$API_READY" = false ]; then
  echo "WARNING: Rancher API not responding after $API_MAX_RETRIES attempts"
  echo "Continuing anyway, will retry authentication..."
fi
echo ""

# ============================================================================# CREATE RANCHER API TOKEN FOR DOWNSTREAM CLUSTER REGISTRATION
# ============================================================================

echo "Creating Rancher API token for downstream cluster registration..."
echo ""

# Step 1: Authenticate with Rancher using admin credentials
# ============================================================================
# CREATE RANCHER API TOKEN FOR DOWNSTREAM CLUSTER REGISTRATION
# ============================================================================

echo "Creating Rancher API token for downstream cluster registration..."
echo ""

# Step 1: Authenticate with Rancher using admin credentials (WITH RETRY)
echo "Step 1: Authenticating with Rancher..."
TEMP_TOKEN=""
AUTH_MAX_RETRIES=10
AUTH_RETRY=0

while [ -z "$TEMP_TOKEN" ] && [ $AUTH_RETRY -lt $AUTH_MAX_RETRIES ]; do
  AUTH_RETRY=$((AUTH_RETRY + 1))
  
  LOGIN_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$RANCHER_PASSWORD\"}" \
    -k "https://$RANCHER_HOSTNAME/v3-public/localProviders/local?action=login")

  # Extract temporary token
  TEMP_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"token":"[^"]*' | head -1 | cut -d'"' -f4)

  if [ -z "$TEMP_TOKEN" ]; then
    echo "  Attempt $AUTH_RETRY/$AUTH_MAX_RETRIES - Rancher auth API not ready, retrying..."
    if [ $AUTH_RETRY -lt $AUTH_MAX_RETRIES ]; then
      sleep 5
    fi
  fi
done

if [ -z "$TEMP_TOKEN" ]; then
  echo "WARNING: Failed to authenticate with Rancher API after $AUTH_MAX_RETRIES attempts"
  echo "  Last response: $LOGIN_RESPONSE"
  echo "  Skipping API token creation - you can create it manually later"
  echo ""
else
  echo "✓ Authenticated with Rancher on attempt $AUTH_RETRY"
  echo ""

  # Step 2: Create permanent API token (WITH RETRY)
  echo "Step 2: Creating API token..."
  API_TOKEN=""
  TOKEN_MAX_RETRIES=5
  TOKEN_RETRY=0

  while [ -z "$API_TOKEN" ] && [ $TOKEN_RETRY -lt $TOKEN_MAX_RETRIES ]; do
    TOKEN_RETRY=$((TOKEN_RETRY + 1))
    
    TOKEN_RESPONSE=$(curl -s -X POST \
      -H "Authorization: Bearer $TEMP_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "type": "token",
        "description": "Terraform automation token for downstream cluster registration",
        "ttl": 0,
        "isDerived": false
      }' \
      -k "https://$RANCHER_HOSTNAME/v3/tokens")

    # Extract the API token
    API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*' | head -1 | cut -d'"' -f4)

    if [ -z "$API_TOKEN" ]; then
      echo "  Attempt $TOKEN_RETRY/$TOKEN_MAX_RETRIES - Token creation not ready, retrying..."
      if [ $TOKEN_RETRY -lt $TOKEN_MAX_RETRIES ]; then
        sleep 5
      fi
    fi
  done

  if [ -z "$API_TOKEN" ]; then
    echo "WARNING: Failed to create API token after $TOKEN_MAX_RETRIES attempts"
    echo "  Last response: $TOKEN_RESPONSE"
    echo "  You can create the token manually via Rancher UI or script"
    echo ""
  else
    echo "✓ API token created successfully on attempt $TOKEN_RETRY"
    echo ""
    echo "=========================================="
    echo "Rancher API Token:"
    echo "=========================================="
    echo "$API_TOKEN"
    echo ""
    
    # Save token to file for downstream cluster registration
    TOKEN_FILE="$CONFIG_PATH/.rancher-api-token"
    echo "$API_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "✓ Token saved to: $TOKEN_FILE"
    echo ""
    echo "Token will be used by Terraform for native downstream cluster registration"
    echo ""
  fi
fi

echo "=========================================="
echo "✓ Rancher Manager Deployment Complete!"
echo "=========================================="
echo ""
echo "Rancher URL: https://$RANCHER_HOSTNAME"
echo "Admin Username: admin"
echo "Admin Password: $RANCHER_PASSWORD"
echo ""
echo "IMPORTANT: Change admin password immediately after first login!"
echo ""
echo "Note: Kubeconfig merging handled by Terraform merge_kubeconfigs resource"
echo "=========================================="
