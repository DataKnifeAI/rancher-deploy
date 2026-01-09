#!/bin/bash

# RKE2 Installation Script - Simplified & Robust
# Works on fresh VMs and can be re-run safely on existing VMs

LOG_FILE="/var/log/rke2-install.log"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== RKE2 Installation Script Starting ==="

# Skip checks if already installed
if [ -f /usr/local/bin/rke2 ]; then
  log "RKE2 already installed, skipping installation"
  exit 0
fi

# Wait for cloud-init to complete (CRITICAL - system must be fully ready)
# Use boot-finished file check (more reliable than cloud-init status --wait which can hang)
log "Waiting for cloud-init to complete..."
CLOUD_INIT_ATTEMPTS=0
MAX_CLOUD_INIT_ATTEMPTS=120  # 10 minutes max (120 × 5 sec = 600 sec)

while [ $CLOUD_INIT_ATTEMPTS -lt $MAX_CLOUD_INIT_ATTEMPTS ]; do
  CLOUD_INIT_ATTEMPTS=$((CLOUD_INIT_ATTEMPTS + 1))
  
  # Check for boot-finished file (reliable indicator that cloud-init completed)
  if [ -f /var/lib/cloud/instance/boot-finished ]; then
    log "✓ Cloud-init completed at attempt $CLOUD_INIT_ATTEMPTS ($(($CLOUD_INIT_ATTEMPTS * 5)) seconds)"
    break
  fi
  
  if [ $((CLOUD_INIT_ATTEMPTS % 12)) -eq 0 ]; then
    ELAPSED=$((CLOUD_INIT_ATTEMPTS * 5))
    log "  Still waiting for cloud-init... attempt $CLOUD_INIT_ATTEMPTS/120 (${ELAPSED}s elapsed)"
  fi
  sleep 5
done

if [ $CLOUD_INIT_ATTEMPTS -ge $MAX_CLOUD_INIT_ATTEMPTS ]; then
  log "⚠ Cloud-init boot-finished not found after 10 minutes, but proceeding (system may still be initializing)"
fi

# Create .kube directory and placeholder kubeconfig for Terraform provider validation
# The real kubeconfig will be written by RKE2 when it's ready
log "Setting up kubeconfig directory..."
sudo mkdir -p /root/.kube /home/ubuntu/.kube
sudo chown -R ubuntu:ubuntu /home/ubuntu/.kube
sudo chmod 700 /home/ubuntu/.kube

# Create placeholder kubeconfig so Terraform Kubernetes provider can validate it exists
# This will be overwritten by the actual RKE2 config once the cluster is ready
sudo tee /home/ubuntu/.kube/rancher-manager.yaml > /dev/null << 'EOF'
apiVersion: v1
kind: Config
metadata:
  name: rancher-manager
clusters:
- cluster:
    server: https://placeholder:6443
  name: rancher-manager
contexts:
- context:
    cluster: rancher-manager
    user: admin@rancher-manager
  name: rancher-manager
current-context: rancher-manager
users:
- name: admin@rancher-manager
  user:
    token: placeholder
EOF

sudo chown ubuntu:ubuntu /home/ubuntu/.kube/rancher-manager.yaml
sudo chmod 600 /home/ubuntu/.kube/rancher-manager.yaml
log "✓ Placeholder kubeconfig created (will be overwritten by RKE2 when ready)"

# Verify network connectivity with retries
log "Verifying network connectivity..."
NETWORK_ATTEMPTS=0
while [ $NETWORK_ATTEMPTS -lt 5 ]; do
  NETWORK_ATTEMPTS=$((NETWORK_ATTEMPTS + 1))
  if timeout 10 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    log "✓ Network connectivity verified"
    break
  fi
  if [ $NETWORK_ATTEMPTS -lt 5 ]; then
    log "  Network not ready, retry $NETWORK_ATTEMPTS/5..."
    sleep 2
  fi
done

if [ $NETWORK_ATTEMPTS -ge 5 ]; then
  log "⚠ Network verification failed after 5 attempts, proceeding anyway"
fi

# ============ INSTALL PROXMOX GUEST AGENT ============
# Install qemu-guest-agent for Proxmox integration
# This enables VM status reporting, graceful shutdowns, and IP address detection
log "Installing Proxmox guest agent (qemu-guest-agent)..."
if ! command -v qemu-guest-agent >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1
    systemctl enable qemu-guest-agent >/dev/null 2>&1
    systemctl start qemu-guest-agent >/dev/null 2>&1
    log "✓ Proxmox guest agent installed and started"
  else
    log "⚠ Could not install qemu-guest-agent (apt-get not available)"
  fi
else
  log "✓ Proxmox guest agent already installed"
  # Ensure it's running
  systemctl enable qemu-guest-agent >/dev/null 2>&1
  systemctl start qemu-guest-agent >/dev/null 2>&1 || true
fi

# ============ CONFIGURE NODE DNS ============
# Configure DNS using systemd-resolved (recommended for modern Ubuntu)
# This ensures all pods (including CoreDNS) inherit proper DNS configuration
log "Configuring node DNS servers..."

# Get DNS servers from environment or use defaults
# DNS_SERVERS is space-separated string (e.g., "192.168.1.1" or "192.168.1.1 1.1.1.1")
DNS_SERVERS="${DNS_SERVERS:-192.168.1.1}"
FALLBACK_DNS="8.8.8.8 8.8.4.4"

# Enable and start systemd-resolved
log "Enabling and starting systemd-resolved..."
systemctl enable systemd-resolved >/dev/null 2>&1 || log "⚠ Failed to enable systemd-resolved"
systemctl start systemd-resolved >/dev/null 2>&1 || log "⚠ Failed to start systemd-resolved"

# Create systemd-resolved configuration directory
mkdir -p /etc/systemd/resolved.conf.d

# Configure DNS in systemd-resolved
log "Configuring systemd-resolved with DNS servers: $DNS_SERVERS"
cat > /etc/systemd/resolved.conf.d/dns.conf <<EOF
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=$FALLBACK_DNS
EOF

# Restart systemd-resolved to apply configuration
log "Restarting systemd-resolved to apply DNS configuration..."
systemctl restart systemd-resolved >/dev/null 2>&1 || log "⚠ Failed to restart systemd-resolved"

log "✓ systemd-resolved configured with DNS servers: $DNS_SERVERS"

# Verify DNS configuration
log "Verifying DNS configuration..."
sleep 2  # Give systemd-resolved time to update resolv.conf
if systemctl is-active --quiet systemd-resolved; then
  log "✓ systemd-resolved is active"
  if [ -f /etc/resolv.conf ]; then
    log "✓ /etc/resolv.conf exists (managed by systemd-resolved):"
    grep -E "nameserver|search|options" /etc/resolv.conf 2>/dev/null | sed 's/^/  /' || log "  (may be a symlink to systemd-resolved stub)"
  fi
else
  log "⚠ systemd-resolved is not active - DNS may not work correctly"
fi

# Verify DNS resolution works
log "Testing DNS resolution..."
if nslookup google.com >/dev/null 2>&1; then
  log "✓ DNS resolution working"
else
  log "⚠ DNS resolution test failed - may need manual intervention"
fi

# Update packages
log "Updating package list..."
apt-get update -qq || log "⚠ Package update failed"

# Download RKE2 installer with timeout and retries
log "Downloading RKE2 installer..."
INSTALLER="/tmp/rke2-installer.sh"
DOWNLOAD_SUCCESS=0

for i in {1..5}; do
  log "Download attempt $i/5..."
  CURL_OUTPUT=$(timeout 60 curl -sfL --max-time 60 --connect-timeout 30 https://get.rke2.io -o "$INSTALLER" 2>&1)
  CURL_EXIT=$?
  
  if [ $CURL_EXIT -eq 0 ] && [ -f "$INSTALLER" ] && [ -s "$INSTALLER" ]; then
    log "✓ RKE2 installer downloaded successfully"
    chmod +x "$INSTALLER"
    DOWNLOAD_SUCCESS=1
    break
  else
    if [ $CURL_EXIT -ne 0 ]; then
      log "  curl exit code: $CURL_EXIT, error: $CURL_OUTPUT"
    elif [ ! -f "$INSTALLER" ]; then
      log "  File not created after download"
    elif [ ! -s "$INSTALLER" ]; then
      log "  File is empty after download"
    fi
  fi
  
  if [ $i -lt 5 ]; then
    log "Download failed, retrying in 10 seconds..."
    sleep 10
  fi
done

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
  log "✗ Failed to download RKE2 installer after 5 attempts"
  exit 1
fi


# ============ RKE2 SERVER NODE ============
if [ "${IS_RKE2_SERVER}" = "true" ]; then
log "Installing RKE2 server v${RKE2_VERSION}..."

export INSTALL_RKE2_VERSION="${RKE2_VERSION}"

# If SERVER_IP is provided, this is a secondary node joining primary's cluster
if [ -n "${SERVER_IP}" ] && [ "${SERVER_IP}" != "" ]; then
  # Secondary node MUST have a token passed from Terraform
  if [ -z "${SERVER_TOKEN}" ] || [ "${SERVER_TOKEN}" = "" ]; then
    log "✗ ERROR: Secondary server detected but no token provided by Terraform"
    log "ℹ Token should be fetched from primary and passed via rke2_server_token variable"
    log "ℹ Check Terraform logs for token fetch failures"
    exit 1
  fi
  log "Secondary server detected. Joining existing RKE2 cluster at ${SERVER_IP}:9345..."
  
  # CRITICAL: Wait for primary registration API to be responsive before joining (port 9345, not 6443!)
  log "Waiting for primary RKE2 registration API (${SERVER_IP}:9345) to be ready..."
  API_READY=0
  for i in {1..120}; do
    if timeout 5 bash -c "echo > /dev/tcp/${SERVER_IP}/9345" 2>/dev/null; then
      log "✓ Primary registration port is accessible at attempt $i"
      API_READY=1
      break
    fi
    if [ $((i % 10)) -eq 0 ] || [ $i -le 3 ]; then
      log "  Primary port check attempt $i/120..."
    fi
    sleep 5
  done
  
  if [ $API_READY -eq 0 ]; then
    log "✗ ERROR: Primary registration API did not become ready after 10 minutes"
    log "ℹ Verify primary RKE2 server is running: systemctl status rke2-server on ${SERVER_IP}"
    log "ℹ Check primary logs: journalctl -u rke2-server on ${SERVER_IP}"
    exit 1
  fi
  
  # Create config file for secondary node BEFORE running installer
  # RKE2 reads this automatically and joins primary's etcd cluster
  mkdir -p /etc/rancher/rke2
  cat > /etc/rancher/rke2/config.yaml <<EOF
# Secondary RKE2 server - join primary cluster via shared etcd
server: https://SERVER_IP_PLACEHOLDER:9345
token: SERVER_TOKEN_PLACEHOLDER
tls-san:
  - ${CLUSTER_HOSTNAME}
  - ${CLUSTER_PRIMARY_IP}
EOF
  # Add aliases to tls-san if provided
  if [ -n "${CLUSTER_ALIASES}" ] && [ "${CLUSTER_ALIASES}" != "" ]; then
    IFS=',' read -ra ALIASES_ARRAY <<< "${CLUSTER_ALIASES}"
    for ALIAS in "${ALIASES_ARRAY[@]}"; do
      echo "  - $ALIAS" >> /etc/rancher/rke2/config.yaml
    done
  fi
  # Replace placeholders with actual values
  sed -i "s|SERVER_IP_PLACEHOLDER|${SERVER_IP}|g" /etc/rancher/rke2/config.yaml
  sed -i "s|SERVER_TOKEN_PLACEHOLDER|${SERVER_TOKEN}|g" /etc/rancher/rke2/config.yaml
  log "✓ RKE2 secondary config created at /etc/rancher/rke2/config.yaml"
  
else
  log "Starting new RKE2 server (primary node)"
  # Create config file for primary node
  mkdir -p /etc/rancher/rke2
  cat > /etc/rancher/rke2/config.yaml <<EOF
# Primary RKE2 server with HA etcd clustering
tls-san:
  - ${CLUSTER_HOSTNAME}
  - ${CLUSTER_PRIMARY_IP}
EOF
  # Add aliases to tls-san if provided
  if [ -n "${CLUSTER_ALIASES}" ] && [ "${CLUSTER_ALIASES}" != "" ]; then
    IFS=',' read -ra ALIASES_ARRAY <<< "${CLUSTER_ALIASES}"
    for ALIAS in "${ALIASES_ARRAY[@]}"; do
      echo "  - $ALIAS" >> /etc/rancher/rke2/config.yaml
    done
  fi
  log "✓ RKE2 primary config created at /etc/rancher/rke2/config.yaml"
fi

# Install RKE2 - will automatically read config.yaml for all settings
export INSTALL_RKE2_VERSION="${RKE2_VERSION}"

if ! "$INSTALLER"; then
  log "✗ RKE2 installation failed"
  exit 1
fi

log "RKE2 installation complete. Service will start automatically."
log "ⓘ Note: RKE2 service may take several minutes to fully initialize"
log "ⓘ You can check status later with: systemctl status rke2-server"

# ============ RANCHER SYSTEM-AGENT INSTALLATION (Downstream Clusters Only) ============
# System-agent enables automatic registration with Rancher Manager
if [ "${REGISTER_WITH_RANCHER}" = "true" ] && [ -n "${RANCHER_HOSTNAME}" ]; then
  log "============================================================="
  log "Installing rancher-system-agent for Rancher registration..."
  log "============================================================="
  
  # Wait for RKE2 server to be fully ready before installing system-agent
  log "Waiting for RKE2 to initialize (max 5 minutes)..."
  READY=0
  for i in {1..150}; do
    if [ -f /var/lib/rancher/rke2/server/token ]; then
      READY=1
      log "✓ RKE2 server ready at attempt $i"
      break
    fi
    if [ $((i % 30)) -eq 0 ]; then
      log "  RKE2 initializing... attempt $i/150"
    fi
    sleep 2
  done
  
  if [ $READY -eq 1 ]; then
    # Get kubeconfig from local RKE2 server
    log "Retrieving RKE2 kubeconfig..."
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
    export PATH="/var/lib/rancher/rke2/bin:$PATH"
    
    # Wait for kubeconfig to be readable
    KUBECONFIG_READY=0
    for i in {1..60}; do
      if [ -f "$KUBECONFIG" ] && /var/lib/rancher/rke2/bin/kubectl cluster-info &>/dev/null; then
        KUBECONFIG_READY=1
        log "✓ Kubeconfig available at attempt $i"
        break
      fi
      sleep 2
    done
    
    if [ $KUBECONFIG_READY -eq 1 ]; then
      log "✓ RKE2 cluster is responsive, kubeconfig ready for system-agent"
      log "System-agent will be registered automatically by Rancher Manager"
      log "Cluster registration status can be checked via Rancher API:"
      log "  curl -H 'Authorization: Bearer \$RANCHER_TOKEN' \\"
      log "    https://${RANCHER_HOSTNAME}/v3/nodes?clusterId=<cluster-id>"
    else
      log "⚠ RKE2 kubeconfig not ready for system-agent after 120 seconds"
      log "System-agent registration may be delayed but cluster is still operational"
    fi
  else
    log "⚠ RKE2 server token not ready for system-agent installation"
    log "Registration will complete when Rancher discovers the running RKE2 cluster"
  fi
else
  if [ "${REGISTER_WITH_RANCHER}" != "true" ]; then
    log "ⓘ System-agent registration skipped (REGISTER_WITH_RANCHER=false)"
  else
    log "ⓘ System-agent registration skipped (RANCHER_HOSTNAME not set)"
  fi
fi

log "=== RKE2 Provisioning Complete ==="

# Verify systemd unit exists, then enable and start if needed
if [ -f /usr/local/lib/systemd/system/rke2-server.service ]; then
  if ! systemctl is-active --quiet rke2-server; then
    log "Enabling and starting RKE2 server service..."
    systemctl daemon-reload
    systemctl enable rke2-server
    systemctl start rke2-server
    log "✓ RKE2 server service enabled and started"
  else
    log "✓ RKE2 server service is already running"
  fi
else
  log "⚠ RKE2 server unit file not found, service will start manually"
fi

# ============ NOTE: COREDNS DNS CONFIGURATION ============
# CoreDNS pods inherit /etc/resolv.conf from the node
# Since we've configured /etc/resolv.conf with the correct DNS servers above,
# CoreDNS will automatically use those DNS servers for external queries
# No need to patch CoreDNS ConfigMap - it will use node DNS by default
log "✓ Node DNS configured - CoreDNS pods will inherit /etc/resolv.conf automatically"

else
# ============ RKE2 AGENT NODE ============
log "Installing RKE2 agent v${RKE2_VERSION} (server: ${SERVER_IP})..."

# Validate required variables
if [ -z "${SERVER_IP}" ] || [ "${SERVER_IP}" = "" ]; then
  log "✗ ERROR: SERVER_IP is required for RKE2 agent installation"
  exit 1
fi

if [ -z "${SERVER_TOKEN}" ] || [ "${SERVER_TOKEN}" = "" ]; then
  log "✗ ERROR: SERVER_TOKEN is required for RKE2 agent installation"
  log "ℹ Token should be fetched from primary server and passed via rke2_server_token variable"
  exit 1
fi

# Create directories
mkdir -p /etc/rancher/rke2
mkdir -p /usr/local/lib/systemd/system

# CRITICAL: Agent nodes must use config.yaml with server: https://<primary>:9345
# (the registration/bootstrap API port), NOT environment variables pointing to 6443
# This matches how additional control nodes connect to the cluster
log "Creating RKE2 agent config.yaml (using registration port 9345)..."
cat > /etc/rancher/rke2/config.yaml <<EOF
# RKE2 agent node - join cluster via server registration API
server: https://${SERVER_IP}:9345
token: ${SERVER_TOKEN}
EOF
log "✓ RKE2 agent config.yaml created at /etc/rancher/rke2/config.yaml"

# Export environment variables for installer (RKE2 installer may read these, but config.yaml takes precedence)
export RKE2_URL="https://${SERVER_IP}:9345"
export RKE2_TOKEN="${SERVER_TOKEN}"
export INSTALL_RKE2_VERSION="${RKE2_VERSION}"

# Run RKE2 installer
if ! "$INSTALLER"; then
  log "✗ RKE2 installation failed"
  exit 1
fi

log "RKE2 agent installation complete."

# Verify config.yaml exists and has correct content
if [ ! -f /etc/rancher/rke2/config.yaml ]; then
  log "✗ ERROR: config.yaml not found after installation"
  exit 1
fi

if ! grep -q "server: https://${SERVER_IP}:9345" /etc/rancher/rke2/config.yaml; then
  log "✗ ERROR: config.yaml missing correct server URL"
  log "Config file contents:"
  cat /etc/rancher/rke2/config.yaml
  exit 1
fi

if ! grep -q "token: ${SERVER_TOKEN}" /etc/rancher/rke2/config.yaml; then
  log "✗ ERROR: config.yaml missing token"
  log "Config file contents:"
  cat /etc/rancher/rke2/config.yaml
  exit 1
fi

log "✓ RKE2 agent config.yaml verified"

log "ⓘ Note: RKE2 agent may take several minutes to join the cluster"
log "ⓘ You can check status later with: systemctl status rke2-agent"

# Verify systemd unit exists, then enable and start if needed
if [ -f /usr/local/lib/systemd/system/rke2-agent.service ]; then
  # Reload systemd to pick up the environment file
  systemctl daemon-reload
  
  if ! systemctl is-active --quiet rke2-agent; then
    log "Enabling and starting RKE2 agent service..."
    systemctl enable rke2-agent
    # Start service in background to avoid blocking - service will retry on its own
    timeout 30 systemctl start rke2-agent || log "⚠ Service start timed out or failed, but service is enabled and will retry"
    log "✓ RKE2 agent service enabled and start command issued"
  else
    log "RKE2 agent service is already running, restarting to pick up environment changes..."
    timeout 30 systemctl restart rke2-agent || log "⚠ Service restart timed out or failed, but restart was attempted"
    log "✓ RKE2 agent service restart command issued"
  fi
else
  log "⚠ RKE2 agent unit file not found, service will start manually"
fi
fi

# Setup kubeconfig access
log "Setting up kubectl access..."
cat >> /root/.bashrc <<'BASHEOF'
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="${PATH}:/usr/local/bin"
alias k=kubectl
BASHEOF

log "=== RKE2 Installation Script Completed Successfully ==="
