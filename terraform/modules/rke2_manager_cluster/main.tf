terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "cluster_name" {
  description = "Cluster name"
  type        = string
}

variable "server_ips" {
  description = "List of manager server node IPs"
  type        = list(string)
}

variable "cluster_hostname" {
  description = "FQDN for the cluster (e.g., manager.dataknife.net) - used in kubeconfig"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "ssh_user" {
  description = "SSH user"
  type        = string
  default     = "ubuntu"
}

variable "dns_servers" {
  description = "DNS servers for CoreDNS forwarding (space-separated)"
  type        = string
  default     = "192.168.1.1 1.1.1.1"
}

# NOTE: RKE2 is installed via cloud-init during VM provisioning
# This module handles cluster verification and kubeconfig retrieval for manager clusters

# Clean up SSH known_hosts for all manager IPs
resource "null_resource" "cleanup_known_hosts" {
  provisioner "local-exec" {
    command = <<-EOT
      for ip in ${join(" ", var.server_ips)}; do
        ssh-keygen -R "$ip" 2>/dev/null || true
      done
      echo "✓ Cleaned up SSH known_hosts for manager cluster"
    EOT
  }
}

# Wait for primary RKE2 server to be ready (token file exists)
# Primary server starts standalone and generates the cluster token
resource "null_resource" "wait_for_primary_server" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for primary RKE2 manager server at ${var.server_ips[0]}..."
      for i in {1..180}; do
        if ssh -i ${var.ssh_private_key_path} -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${var.ssh_user}@${var.server_ips[0]} 'sudo test -f /var/lib/rancher/rke2/server/node-token' 2>/dev/null; then
          echo "✓ Primary RKE2 manager server is ready at attempt $i"
          exit 0
        fi
        
        if [ $((i % 30)) -eq 0 ]; then
          echo "  Still waiting... attempt $i/180 (at $((i * 2)) seconds)"
        fi
        sleep 2
      done
      echo "✗ Primary RKE2 server never became ready after 6 minutes"
      exit 1
    EOT
  }

  depends_on = [null_resource.cleanup_known_hosts]
}

# Wait for secondary manager servers to join the HA cluster
# Secondary servers fetch the token from primary and join as control-plane nodes
resource "null_resource" "wait_for_secondary_servers" {
  count = length(var.server_ips) > 1 ? length(var.server_ips) - 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for secondary RKE2 manager server at ${var.server_ips[count.index + 1]} to join cluster..."
      for i in {1..180}; do
        if ssh -i ${var.ssh_private_key_path} -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${var.ssh_user}@${var.server_ips[count.index + 1]} 'sudo systemctl is-active --quiet rke2-server' 2>/dev/null; then
          echo "✓ Secondary manager server ${var.server_ips[count.index + 1]} is active"
          exit 0
        fi
        
        if [ $((i % 30)) -eq 0 ]; then
          echo "  Still waiting for ${var.server_ips[count.index + 1]}... attempt $i/180"
        fi
        sleep 2
      done
      echo "✗ Secondary manager server ${var.server_ips[count.index + 1]} never became ready"
      exit 1
    EOT
  }

  depends_on = [null_resource.wait_for_primary_server]
}

# Retrieve REAL kubeconfig from primary manager server
# (Overwrites the placeholder kubeconfig created during cloud-init)
resource "null_resource" "get_kubeconfig" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Retrieving actual kubeconfig from RKE2 primary server..."
      mkdir -p ~/.kube
      # Retrieve kubeconfig and set proper cluster/context names
      # RKE2 creates "default" for cluster, context, and current-context
      # We replace them with meaningful names: ${var.cluster_name}
      ssh -i ${var.ssh_private_key_path} -o StrictHostKeyChecking=no ${var.ssh_user}@${var.server_ips[0]} 'sudo cat /etc/rancher/rke2/rke2.yaml' | \
        sed 's/127.0.0.1/${var.cluster_hostname}/' | \
        sed '/^clusters:/,/^contexts:/ s/^  name: default$/  name: ${var.cluster_name}/' | \
        sed '/^contexts:/,/^current-context:/ s/^    cluster: default$/    cluster: ${var.cluster_name}/' | \
        sed '/^contexts:/,/^current-context:/ s/^  name: default$/  name: ${var.cluster_name}/' | \
        sed 's/^current-context: default$/current-context: ${var.cluster_name}/' > ~/.kube/${var.cluster_name}.yaml
      chmod 600 ~/.kube/${var.cluster_name}.yaml
      echo "✓ Manager kubeconfig updated with real credentials and context name"
    EOT
  }

  depends_on = [null_resource.wait_for_secondary_servers]
}

# Configure CoreDNS to forward dataknife.net queries to internal DNS (192.168.1.1)
# This ensures internal domains resolve even if nodes don't have 192.168.1.1 in their DNS config
resource "null_resource" "configure_coredns_forwarding" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "=========================================="
      echo "Configuring CoreDNS Forwarding for dataknife.net"
      echo "=========================================="
      
      PRIMARY_IP="${var.server_ips[0]}"
      SSH_KEY="${var.ssh_private_key_path}"
      SSH_USER="${var.ssh_user}"
      INTERNAL_DNS="192.168.1.1"
      
      echo "Waiting for CoreDNS to be ready on $PRIMARY_IP..."
      for i in {1..60}; do
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$PRIMARY_IP" \
          'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get configmap -n kube-system rke2-coredns-rke2-coredns-config &>/dev/null 2>&1'; then
          echo "✓ CoreDNS ConfigMap found at attempt $i"
          break
        fi
        if [ $i -eq 60 ]; then
          echo "⚠ CoreDNS ConfigMap not found after 120 seconds, skipping patching..."
          exit 0
        fi
        sleep 2
      done
      
      echo "Patching CoreDNS ConfigMap to forward dataknife.net to $INTERNAL_DNS..."
      
      # Patch CoreDNS ConfigMap to add forward for dataknife.net
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$PRIMARY_IP" <<'REMOTE_SCRIPT'
        set -e
        
        KUBECTL="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml"
        CONFIGMAP_NAME="rke2-coredns-rke2-coredns-config"
        NAMESPACE="kube-system"
        INTERNAL_DNS="192.168.1.1"
        
        # Get current Corefile
        CURRENT_COREFILE=$($KUBECTL get configmap -n "$NAMESPACE" "$CONFIGMAP_NAME" -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")
        
        if [ -z "$CURRENT_COREFILE" ]; then
          echo "⚠ Could not retrieve Corefile, skipping patching"
          exit 0
        fi
        
        # Check if dataknife.net forwarding already exists
        if echo "$CURRENT_COREFILE" | grep -q "dataknife.net"; then
          echo "✓ dataknife.net forwarding already configured in CoreDNS"
          exit 0
        fi
        
        # Create new Corefile with dataknife.net forwarding block prepended
        # The dataknife.net block must come before the "." block for priority
        DATAKNIFE_BLOCK="dataknife.net:53 {
    errors
    cache 30
    forward . $INTERNAL_DNS
    log
}
"
        
        # Prepend dataknife.net block to existing Corefile
        NEW_COREFILE="$DATAKNIFE_BLOCK$CURRENT_COREFILE"
        
        # Write to temp file and update ConfigMap
        echo "$NEW_COREFILE" > /tmp/coredns-corefile-new
        $KUBECTL create configmap "$CONFIGMAP_NAME" \
          --from-file=Corefile=/tmp/coredns-corefile-new \
          --dry-run=client -o yaml | \
          $KUBECTL replace -f - -n "$NAMESPACE" 2>/dev/null || {
          echo "⚠ Failed to update CoreDNS ConfigMap, trying patch method..."
          
          # Alternative: use kubectl patch with JSON
          COREFILE_JSON=$(echo "$NEW_COREFILE" | jq -Rs .)
          $KUBECTL patch configmap -n "$NAMESPACE" "$CONFIGMAP_NAME" \
            --type merge \
            -p "{\"data\":{\"Corefile\":$COREFILE_JSON}}" || \
          echo "⚠ Could not update CoreDNS ConfigMap - manual intervention may be required"
        }
        
        rm -f /tmp/coredns-corefile-new
        
        # Restart CoreDNS pods to apply changes
        echo "Restarting CoreDNS pods to apply configuration..."
        $KUBECTL rollout restart deployment -n "$NAMESPACE" rke2-coredns-rke2-coredns || \
          $KUBECTL delete pods -n "$NAMESPACE" -l k8s-app=rke2-coredns-rke2-coredns || true
        
        echo "✓ CoreDNS forwarding configured for dataknife.net -> $INTERNAL_DNS"
REMOTE_SCRIPT
      
      echo "✓ CoreDNS configuration completed"
    EOT
  }

  depends_on = [null_resource.get_kubeconfig]
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = "~/.kube/${var.cluster_name}.yaml"
}

output "api_server_url" {
  description = "Kubernetes API server URL"
  value       = "https://${var.cluster_hostname}:6443"
}

output "cluster_name" {
  description = "Cluster name"
  value       = var.cluster_name
}
