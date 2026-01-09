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

variable "agent_ips" {
  description = "List of agent node IPs"
  type        = list(string)
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

variable "cluster_hostname" {
  description = "FQDN for the cluster (e.g., nprd-apps.dataknife.net) - used in kubeconfig"
  type        = string
}

variable "dns_servers" {
  description = "DNS servers for CoreDNS forwarding (space-separated)"
  type        = string
  default     = "192.168.1.1 1.1.1.1"
}

variable "primary_server_ip" {
  description = "Primary RKE2 server IP (for worker node token fix)"
  type        = string
  default     = ""
}

variable "primary_server_token" {
  description = "Primary RKE2 server token (for worker node token fix)"
  type        = string
  default     = ""
  sensitive   = true
}

# NOTE: RKE2 is installed via cloud-init during VM provisioning
# This module handles verification and kubeconfig retrieval for downstream clusters

# Clean up SSH known_hosts for all agent IPs
resource "null_resource" "cleanup_known_hosts" {
  provisioner "local-exec" {
    command = <<-EOT
      for ip in ${join(" ", var.agent_ips)}; do
        ssh-keygen -R "$ip" 2>/dev/null || true
      done
      echo "✓ Cleaned up SSH known_hosts for downstream agent cluster"
    EOT
  }
}

# Fix missing token on worker nodes (runs before wait check)
# This fixes an issue where worker nodes may have been provisioned before the token was available
resource "null_resource" "fix_worker_node_tokens" {
  count = var.primary_server_ip != "" && var.primary_server_token != "" ? length(var.agent_ips) : 0

  provisioner "local-exec" {
    command = <<-EOT
      NODE_IP="${var.agent_ips[count.index]}"
      PRIMARY_IP="${var.primary_server_ip}"
      TOKEN="${var.primary_server_token}"
      SSH_KEY="${var.ssh_private_key_path}"
      SSH_USER="${var.ssh_user}"
      
      # Check if this is a worker node (rke2-agent) and if token is missing
      if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$NODE_IP" \
        'systemctl list-units --type=service --state=active | grep -q rke2-agent.service' 2>/dev/null; then
        
        # Check if token is missing from systemd env file
        TOKEN_MISSING=$(ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$NODE_IP" \
          'sudo test -f /usr/local/lib/systemd/system/rke2-agent.env && ! grep -q "RKE2_TOKEN=" /usr/local/lib/systemd/system/rke2-agent.env || ! grep -q "$TOKEN" /usr/local/lib/systemd/system/rke2-agent.env; echo $?' 2>/dev/null || echo "1")
        
        if [ "$TOKEN_MISSING" = "0" ] || [ "$TOKEN_MISSING" = "1" ]; then
          echo "Fixing missing token on worker node $NODE_IP..."
          
          # Create/update systemd environment file
          ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NODE_IP" \
            "sudo bash -c 'cat > /usr/local/lib/systemd/system/rke2-agent.env <<EOF
RKE2_URL=https://$PRIMARY_IP:6443
RKE2_TOKEN=$TOKEN
EOF
'"
          
          # Reload systemd and restart service
          ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NODE_IP" \
            'sudo systemctl daemon-reload && sudo systemctl restart rke2-agent' 2>/dev/null || true
          
          echo "✓ Token fixed on worker node $NODE_IP"
        else
          echo "✓ Token already present on worker node $NODE_IP"
        fi
      fi
    EOT
  }

  depends_on = [null_resource.cleanup_known_hosts]
}

# Wait for all nodes to be ready (RKE2 agent or server service running)
# Supports both downstream agent clusters and HA server clusters
resource "null_resource" "wait_for_agent_nodes" {
  count = length(var.agent_ips)

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for RKE2 node at ${var.agent_ips[count.index]}..."
      for i in {1..180}; do
        # Check for either rke2-agent (downstream) or rke2-server (HA cluster)
        if ssh -i ${var.ssh_private_key_path} -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${var.ssh_user}@${var.agent_ips[count.index]} 'sudo systemctl is-active --quiet rke2-agent || sudo systemctl is-active --quiet rke2-server' 2>/dev/null; then
          echo "✓ RKE2 node ${var.agent_ips[count.index]} is ready at attempt $i"
          exit 0
        fi
        
        if [ $((i % 30)) -eq 0 ]; then
          echo "  Still waiting for ${var.agent_ips[count.index]}... attempt $i/180"
        fi
        sleep 2
      done
      echo "✗ RKE2 node ${var.agent_ips[count.index]} never became ready"
      exit 1
    EOT
  }

  depends_on = [null_resource.cleanup_known_hosts]
}

# Retrieve kubeconfig from primary downstream node
resource "null_resource" "get_kubeconfig" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Retrieving actual kubeconfig from RKE2 downstream server..."
      mkdir -p ~/.kube
      # Retrieve kubeconfig and set proper cluster/context names
      # RKE2 creates "default" for cluster, context, and current-context
      # We replace them with meaningful names: ${var.cluster_name}
      ssh -i ${var.ssh_private_key_path} -o StrictHostKeyChecking=no ${var.ssh_user}@${var.agent_ips[0]} 'sudo cat /etc/rancher/rke2/rke2.yaml' | \
        sed 's/127.0.0.1/${var.cluster_hostname}/' | \
        sed '/^clusters:/,/^contexts:/ s/^  name: default$/  name: ${var.cluster_name}/' | \
        sed '/^contexts:/,/^current-context:/ s/^    cluster: default$/    cluster: ${var.cluster_name}/' | \
        sed '/^contexts:/,/^current-context:/ s/^  name: default$/  name: ${var.cluster_name}/' | \
        sed 's/^current-context: default$/current-context: ${var.cluster_name}/' > ~/.kube/${var.cluster_name}.yaml
      chmod 600 ~/.kube/${var.cluster_name}.yaml
      echo "✓ Downstream kubeconfig updated with real credentials and context name"
    EOT
  }

  depends_on = [null_resource.wait_for_agent_nodes]
}

# Configure CoreDNS to forward dataknife.net queries to internal DNS (192.168.1.1)
# This ensures internal domains resolve even if nodes don't have 192.168.1.1 in their DNS config
resource "null_resource" "configure_coredns_forwarding" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "=========================================="
      echo "Configuring CoreDNS Forwarding for dataknife.net"
      echo "=========================================="
      
      PRIMARY_IP="${var.agent_ips[0]}"
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
      
      # Verify DNS resolution works
      echo ""
      echo "Verifying DNS resolution..."
      if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$PRIMARY_IP" \
        "nslookup rancher.dataknife.net &>/dev/null 2>&1"; then
        echo "✓ DNS resolution working"
      else
        echo "⚠ DNS resolution check failed (may take a moment for CoreDNS to restart)"
      fi
    EOT
  }

  depends_on = [null_resource.get_kubeconfig]
}

output "api_server_url" {
  description = "Kubernetes API server URL"
  value       = "https://${var.cluster_hostname}:6443"
}

output "cluster_name" {
  description = "Cluster name"
  value       = var.cluster_name
}

output "agent_count" {
  description = "Number of agent nodes"
  value       = length(var.agent_ips)
}
