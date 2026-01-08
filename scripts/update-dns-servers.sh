#!/bin/bash
# Update DNS servers on all deployed VMs
# This script updates /etc/resolv.conf on existing VMs without reprovisioning
# DNS servers and cluster IPs are sourced from terraform.tfvars

set -e

# Configuration
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-ubuntu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Find terraform.tfvars file
TFVARS_FILE="${TFVARS_FILE:-$PROJECT_ROOT/terraform/terraform.tfvars}"

if [ ! -f "$TFVARS_FILE" ]; then
  echo "Error: terraform.tfvars not found at $TFVARS_FILE"
  echo "Please set TFVARS_FILE environment variable or ensure terraform/terraform.tfvars exists"
  exit 1
fi

# Function to extract value from tfvars (handles arrays and strings)
extract_tfvars_value() {
  local cluster_name=$1
  local key=$2
  local tfvars=$3
  
  # Remove comments and find the value within the cluster block
  awk -v cluster="$cluster_name" -v key="$key" '
    BEGIN { in_cluster=0; found=0; brace_level=0 }
    {
      # Remove inline comments
      gsub(/#.*$/, "")
      # Skip empty lines
      if (NF == 0) next
    }
    /^[[:space:]]*'"$cluster_name"'[[:space:]]*=[[:space:]]*\{/ { 
      in_cluster=1
      brace_level=1
      next
    }
    in_cluster {
      # Track brace nesting
      gsub(/\{/, " { ", $0)
      gsub(/\}/, " } ", $0)
      for (i=1; i<=NF; i++) {
        if ($i == "{") brace_level++
        if ($i == "}") brace_level--
        if (brace_level == 0) { in_cluster=0; exit }
      }
      
      # Check if this line contains the key
      if ($0 ~ key) {
        # Handle array values like dns_servers = ["192.168.1.1"]
        if ($0 ~ /\[/) {
          # Extract content between brackets
          match($0, /\[[^\]]*\]/)
          if (RSTART > 0) {
            value = substr($0, RSTART+1, RLENGTH-2)
            gsub(/"/, "", value)
            gsub(/,[[:space:]]*/, " ", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            found=1
            exit
          }
        }
        # Handle string values
        else {
          # Extract value after =
          match($0, /=[[:space:]]*["]?[^"]*["]?/)
          if (RSTART > 0) {
            value = substr($0, RSTART+1)
            gsub(/^[[:space:]]*["]?|["][[:space:]]*$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            found=1
            exit
          }
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$tfvars"
}

# Function to extract numeric value from tfvars
extract_tfvars_number() {
  local cluster_name=$1
  local key=$2
  local tfvars=$3
  
  awk -v cluster="$cluster_name" -v key="$key" '
    BEGIN { in_cluster=0; brace_level=0 }
    {
      # Remove inline comments
      gsub(/#.*$/, "")
      if (NF == 0) next
    }
    /^[[:space:]]*'"$cluster_name"'[[:space:]]*=[[:space:]]*\{/ { 
      in_cluster=1
      brace_level=1
      next
    }
    in_cluster {
      # Track brace nesting
      gsub(/\{/, " { ", $0)
      gsub(/\}/, " } ", $0)
      for (i=1; i<=NF; i++) {
        if ($i == "{") brace_level++
        if ($i == "}") brace_level--
        if (brace_level == 0) { in_cluster=0; exit }
      }
      
      if ($0 ~ key) {
        # Extract number after =
        match($0, /=[[:space:]]*[0-9]+/)
        if (RSTART > 0) {
          value = substr($0, RSTART+1)
          gsub(/[^0-9]/, "", value)
          print value
          exit
        }
      }
    }
  ' "$tfvars"
}

# Parse DNS servers from manager cluster (use first cluster found)
DNS_SERVERS_TFVARS=$(extract_tfvars_value "manager" "dns_servers" "$TFVARS_FILE" 2>/dev/null || echo "")

if [ -z "$DNS_SERVERS_TFVARS" ]; then
  # Try nprd-apps cluster
  DNS_SERVERS_TFVARS=$(extract_tfvars_value "nprd-apps" "dns_servers" "$TFVARS_FILE" 2>/dev/null || echo "")
fi

# Use DNS_SERVERS from environment if set, otherwise use tfvars, otherwise default
if [ -n "$DNS_SERVERS" ] && [ "$DNS_SERVERS" != "192.168.1.1" ]; then
  # User explicitly set DNS_SERVERS, use it
  :
elif [ -n "$DNS_SERVERS_TFVARS" ]; then
  DNS_SERVERS="$DNS_SERVERS_TFVARS"
else
  echo "⚠  Warning: Could not parse DNS servers from tfvars, using default: 192.168.1.1"
  DNS_SERVERS="${DNS_SERVERS:-192.168.1.1}"
fi

# Parse manager cluster configuration
MANAGER_SUBNET=$(extract_tfvars_value "manager" "ip_subnet" "$TFVARS_FILE" 2>/dev/null | tr -d ' ' || echo "")
if [ -z "$MANAGER_SUBNET" ]; then
  echo "⚠  Warning: Could not parse manager ip_subnet from tfvars, using default: 192.168.1"
  MANAGER_SUBNET="192.168.1"
fi

MANAGER_START=$(extract_tfvars_number "manager" "ip_start_octet" "$TFVARS_FILE" 2>/dev/null || echo "")
if [ -z "$MANAGER_START" ]; then
  echo "⚠  Warning: Could not parse manager ip_start_octet from tfvars, using default: 100"
  MANAGER_START="100"
fi

MANAGER_COUNT=$(extract_tfvars_number "manager" "node_count" "$TFVARS_FILE" 2>/dev/null || echo "")
if [ -z "$MANAGER_COUNT" ]; then
  echo "⚠  Warning: Could not parse manager node_count from tfvars, using default: 3"
  MANAGER_COUNT="3"
fi

# Parse apps cluster configuration
APPS_SUBNET=$(extract_tfvars_value "nprd-apps" "ip_subnet" "$TFVARS_FILE" 2>/dev/null | tr -d ' ' || echo "")
if [ -z "$APPS_SUBNET" ]; then
  echo "⚠  Warning: Could not parse nprd-apps ip_subnet from tfvars, using default: 192.168.1"
  APPS_SUBNET="192.168.1"
fi

APPS_START=$(extract_tfvars_number "nprd-apps" "ip_start_octet" "$TFVARS_FILE" 2>/dev/null || echo "")
if [ -z "$APPS_START" ]; then
  echo "⚠  Warning: Could not parse nprd-apps ip_start_octet from tfvars, using default: 110"
  APPS_START="110"
fi

APPS_COUNT=$(extract_tfvars_number "nprd-apps" "node_count" "$TFVARS_FILE" 2>/dev/null || echo "")
if [ -z "$APPS_COUNT" ]; then
  echo "⚠  Warning: Could not parse nprd-apps node_count from tfvars, using default: 3"
  APPS_COUNT="3"
fi

APPS_WORKER_COUNT=$(extract_tfvars_number "nprd-apps" "worker_count" "$TFVARS_FILE" 2>/dev/null || echo "")
if [ -z "$APPS_WORKER_COUNT" ]; then
  APPS_WORKER_COUNT="0"
fi

# Generate manager cluster IPs
MANAGER_IPS=()
for i in $(seq 0 $((MANAGER_COUNT - 1))); do
  octet=$((MANAGER_START + i))
  MANAGER_IPS+=("${MANAGER_SUBNET}.${octet}")
done

# Generate apps cluster server IPs
APPS_SERVER_IPS=()
for i in $(seq 0 $((APPS_COUNT - 1))); do
  octet=$((APPS_START + i))
  APPS_SERVER_IPS+=("${APPS_SUBNET}.${octet}")
done

# Generate apps cluster worker IPs
APPS_WORKER_IPS=()
if [ "$APPS_WORKER_COUNT" -gt 0 ]; then
  worker_start=$((APPS_START + APPS_COUNT))
  for i in $(seq 0 $((APPS_WORKER_COUNT - 1))); do
    octet=$((worker_start + i))
    APPS_WORKER_IPS+=("${APPS_SUBNET}.${octet}")
  done
fi

# Combine all IPs
ALL_IPS=("${MANAGER_IPS[@]}" "${APPS_SERVER_IPS[@]}" "${APPS_WORKER_IPS[@]}")

# Function to update DNS on a single VM
update_dns_on_vm() {
  local ip=$1
  local dns_servers=$2
  
  echo "=========================================="
  echo "Updating DNS on $ip"
  echo "=========================================="
  
  # Check if VM is reachable
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$ip" "echo 'Connection successful'" &>/dev/null; then
    echo "⚠  Cannot connect to $ip, skipping..."
    return 1
  fi
  
  # Get current DNS configuration
  echo "Current DNS configuration:"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$ip" "cat /etc/resolv.conf" 2>/dev/null || echo "  (Could not read /etc/resolv.conf)"
  echo ""
  
  # Update DNS configuration
  echo "Updating DNS servers to: $dns_servers"
  
  local ssh_exit_code=0
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o LogLevel=ERROR "$SSH_USER@$ip" bash -s -- "$dns_servers" <<'REMOTE_SCRIPT' || ssh_exit_code=$?
    DNS_SERVERS="$1"
    
    # Remove immutable flag if it exists (only if it's a regular file)
    if [ ! -L /etc/resolv.conf ]; then
      sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    # Remove symlink if it exists (systemd-resolved creates a symlink)
    if [ -L /etc/resolv.conf ]; then
      sudo rm -f /etc/resolv.conf
    fi
    
    # Ensure systemd-resolved is stopped and disabled
    sudo systemctl stop systemd-resolved 2>/dev/null || true
    sudo systemctl disable systemd-resolved 2>/dev/null || true
    
    # Get domain from hostname if available
    DOMAIN=$(hostname -d 2>/dev/null || echo "")
    
    # Create new /etc/resolv.conf
    {
      echo "# DNS configuration for RKE2 cluster"
      echo "# Updated by update-dns-servers.sh"
      for dns in $DNS_SERVERS; do
        echo "nameserver $dns"
      done
      if [ -n "$DOMAIN" ]; then
        echo "search $DOMAIN"
      fi
      echo "options edns0"
    } | sudo tee /etc/resolv.conf > /dev/null
    
    # Make resolv.conf immutable again
    sudo chattr +i /etc/resolv.conf 2>/dev/null || echo "⚠  Could not make resolv.conf immutable (chattr not available)"
    
    # Verify configuration
    echo ""
    echo "Updated DNS configuration:"
    cat /etc/resolv.conf
REMOTE_SCRIPT
  
  if [ $ssh_exit_code -eq 0 ]; then
    echo "✓ DNS updated successfully on $ip"
    return 0
  else
    echo "✗ Failed to update DNS on $ip (exit code: $ssh_exit_code)"
    return 1
  fi
  
  echo ""
}

# Function to restart CoreDNS pods (optional)
restart_coredns() {
  local ip=$1
  local kubectl="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml"
  
  echo "Restarting CoreDNS pods on $ip..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$ip" \
    "$kubectl delete pod -n kube-system -l k8s-app=kube-dns --ignore-not-found=true" 2>/dev/null || true
  
  echo "  Waiting for CoreDNS pods to be ready..."
  sleep 5
  
  # Check if CoreDNS is ready
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$ip" \
    "$kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" | grep -q "True"; then
    echo "  ✓ CoreDNS pods ready"
  else
    echo "  ⚠  CoreDNS pods may still be starting"
  fi
}

# Main execution
echo "=========================================="
echo "Update DNS Servers on Deployed VMs"
echo "=========================================="
echo ""
echo "Configuration source: $TFVARS_FILE"
echo ""
echo "DNS Servers: $DNS_SERVERS"
echo "SSH Key: $SSH_KEY"
echo "SSH User: $SSH_USER"
echo ""
echo "VMs to update:"
echo "  Manager cluster (${MANAGER_COUNT} nodes): ${MANAGER_IPS[*]}"
if [ ${#APPS_SERVER_IPS[@]} -gt 0 ]; then
  echo "  Apps server nodes (${APPS_COUNT} nodes): ${APPS_SERVER_IPS[*]}"
fi
if [ ${#APPS_WORKER_IPS[@]} -gt 0 ]; then
  echo "  Apps worker nodes (${APPS_WORKER_COUNT} nodes): ${APPS_WORKER_IPS[*]}"
fi
echo ""
echo "Total VMs: ${#ALL_IPS[@]}"
echo ""

# Ask for confirmation
read -p "Continue with DNS update? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "Starting DNS update..."
echo ""

# Update DNS on all VMs
SUCCESS=0
FAILED=0

for ip in "${ALL_IPS[@]}"; do
  if update_dns_on_vm "$ip" "$DNS_SERVERS"; then
    ((SUCCESS++)) || true
  else
    ((FAILED++)) || true
  fi
done

echo ""
echo "=========================================="
echo "DNS Update Summary"
echo "=========================================="
echo "Successful: $SUCCESS"
echo "Failed: $FAILED"
echo ""

# Ask if user wants to restart CoreDNS pods
if [ $SUCCESS -gt 0 ]; then
  read -p "Restart CoreDNS pods to pick up new DNS configuration? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Restarting CoreDNS pods on cluster nodes..."
    echo ""
    
    # Restart CoreDNS on manager cluster (first node)
    if [ ${#MANAGER_IPS[@]} -gt 0 ]; then
      restart_coredns "${MANAGER_IPS[0]}"
    fi
    
    # Restart CoreDNS on apps cluster (first server node)
    if [ ${#APPS_SERVER_IPS[@]} -gt 0 ]; then
      restart_coredns "${APPS_SERVER_IPS[0]}"
    fi
  fi
fi

echo ""
echo "=========================================="
echo "DNS Update Complete"
echo "=========================================="
echo ""
echo "Note: CoreDNS pods will automatically inherit the new DNS configuration"
echo "from /etc/resolv.conf. You may need to restart pods manually if they"
echo "don't pick up the changes immediately."
echo ""
