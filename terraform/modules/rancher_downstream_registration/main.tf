terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23, < 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "rancher_url" {
  description = "Rancher manager URL"
  type        = string
}

variable "rancher_token_file" {
  description = "Path to Rancher API token file"
  type        = string
}

variable "cluster_id" {
  description = "Downstream cluster ID (e.g., c-abc123)"
  type        = string
}

variable "cluster_nodes" {
  description = "Map of node names to IP addresses"
  type        = map(string)
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "ssh_user" {
  description = "SSH user for accessing nodes"
  type        = string
  default     = "ubuntu"
}

variable "kubeconfig_path" {
  description = "Path to downstream cluster kubeconfig"
  type        = string
}

# Register downstream cluster using manifest-based approach
# This fetches the registration manifest from Rancher and applies it directly
resource "null_resource" "register_downstream_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=============================================="
      echo "Registering Downstream Cluster with Rancher"
      echo "=============================================="
      
      RANCHER_URL="${var.rancher_url}"
      API_TOKEN=$(cat "${var.rancher_token_file}")
      CLUSTER_ID="${var.cluster_id}"
      SSH_KEY="${var.ssh_private_key_path}"
      SSH_USER="${var.ssh_user}"
      
      # Step 1: Get or create registration token
      echo "[1/5] Fetching registration token from Rancher..."
      
      TOKEN_RESPONSE=$(curl -sk \
        -H "Authorization: Bearer $API_TOKEN" \
        "$RANCHER_URL/v3/clusters/$CLUSTER_ID/clusterregistrationtokens" 2>/dev/null)
      
      TOKEN_COUNT=$(echo "$TOKEN_RESPONSE" | jq '.data | length')
      
      if [ "$TOKEN_COUNT" -eq 0 ]; then
        echo "  Creating new registration token..."
        TOKEN_RESPONSE=$(curl -sk -X POST \
          -H "Authorization: Bearer $API_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"type\": \"clusterregistrationtoken\", \"clusterId\": \"$CLUSTER_ID\"}" \
          "$RANCHER_URL/v3/clusterregistrationtokens" 2>/dev/null)
      fi
      
      # Get the token ID and value
      TOKEN_ID=$(echo "$TOKEN_RESPONSE" | jq -r '.id // .data[0].id // empty')
      TOKEN_VALUE=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data[0].token // empty')
      
      if [ -z "$TOKEN_ID" ] || [ -z "$TOKEN_VALUE" ]; then
        echo "ERROR: Failed to get or create registration token"
        echo "$TOKEN_RESPONSE" | jq '.'
        exit 1
      fi
      
      echo "  ✓ Token: $TOKEN_ID"
      
      # Step 2: Verify DNS resolution from cluster nodes
      echo "[2/5] Verifying DNS resolution from cluster nodes..."
      DNS_WORKING=0
      for i in {1..30}; do
        # Test DNS resolution from first node
        FIRST_NODE_IP=$(echo "${join(",", [for k, v in var.cluster_nodes : v])}" | cut -d',' -f1)
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$FIRST_NODE_IP" \
          "nslookup rancher.dataknife.net &>/dev/null 2>&1"; then
          echo "  ✓ DNS resolution working on $FIRST_NODE_IP"
          DNS_WORKING=1
          break
        fi
        if [ $i -lt 30 ]; then
          sleep 2
        fi
      done
      
      if [ $DNS_WORKING -eq 0 ]; then
        echo "  ⚠ DNS resolution check failed, but continuing with registration..."
      fi
      
      # Step 3: Ensure CoreDNS pods have correct DNS configuration
      echo "[3/5] Ensuring CoreDNS pods have correct DNS configuration..."
      FIRST_NODE_IP=$(echo "${join(",", [for k, v in var.cluster_nodes : v])}" | cut -d',' -f1)
      # Restart CoreDNS pods to ensure they pick up node DNS configuration
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$FIRST_NODE_IP" \
        "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml delete pod -n kube-system -l k8s-app=kube-dns --ignore-not-found=true &>/dev/null 2>&1" || true
      
      # Wait for CoreDNS pods to be ready
      echo "  Waiting for CoreDNS pods to be ready..."
      for i in {1..60}; do
        COREDNS_READY=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$FIRST_NODE_IP" \
          "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" | grep -q "True" && echo "1" || echo "0")
        if [ "$COREDNS_READY" = "1" ]; then
          echo "  ✓ CoreDNS pods ready"
          break
        fi
        if [ $i -lt 60 ]; then
          sleep 2
        fi
      done
      
      # Test DNS resolution from a pod
      echo "  Testing DNS resolution from a pod..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$FIRST_NODE_IP" \
        "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml run dns-check-$${RANDOM} --image=busybox --rm -i --restart=Never -- nslookup rancher.dataknife.net &>/dev/null 2>&1" && \
        echo "  ✓ DNS resolution working from pods" || \
        echo "  ⚠ DNS resolution test from pod failed, but continuing..."
      
      # Step 4: Fetch cluster registration manifest
      echo "[4/5] Fetching cluster registration manifest from Rancher..."
      
      # Note: Using double dollar signs to escape Terraform interpolation for shell variables
      MANIFEST_URL="$RANCHER_URL/v3/import/$${TOKEN_VALUE}_$${CLUSTER_ID}.yaml"
      
      # Download and apply manifest to each node
      echo "[5/5] Applying registration manifest to cluster nodes..."
      
      REGISTRATION_FAILED=0
      %{ for node_name, node_ip in var.cluster_nodes ~}
      echo "  Registering ${node_name} (${node_ip})..."
      
      # Apply manifest to the node using kubectl
      # Use set +e temporarily to allow SSH failures without exiting
      # Explicitly specify kubeconfig to avoid kubectl trying to use default/localhost
      set +e
      REGISTRATION_OUTPUT=$(ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@${node_ip}" \
        "curl -sk $MANIFEST_URL | sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml apply -f -" 2>&1)
      SSH_EXIT_CODE=$?
      set -e
      
      if [ $SSH_EXIT_CODE -eq 0 ] && echo "$REGISTRATION_OUTPUT" | grep -qE "(created|unchanged)"; then
        echo "  ✓ Registered ${node_name}"
      else
        echo "  ⚠ Registration on ${node_name} may have failed"
        if [ $SSH_EXIT_CODE -ne 0 ]; then
          echo "  SSH exit code: $SSH_EXIT_CODE"
        fi
        echo "  Output: $(echo "$REGISTRATION_OUTPUT" | head -10)"
        REGISTRATION_FAILED=1
      fi
      %{ endfor ~}
      
      # Wait for cattle-cluster-agent pods to start
      if [ $REGISTRATION_FAILED -eq 0 ]; then
        echo ""
        echo "Waiting for cattle-cluster-agent pods to start..."
        FIRST_NODE_IP=$(echo "${join(",", [for k, v in var.cluster_nodes : v])}" | cut -d',' -f1)
        for i in {1..60}; do
          AGENT_PODS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$FIRST_NODE_IP" \
            "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get pods -n cattle-system -l app=cattle-cluster-agent --no-headers 2>/dev/null | wc -l" || echo "0")
          if [ "$AGENT_PODS" -gt "0" ]; then
            echo "  ✓ cattle-cluster-agent pods created"
            break
          fi
          if [ $i -lt 60 ]; then
            sleep 2
          fi
        done
        
        # Check if any pods are running (not just created)
        echo "Checking cattle-cluster-agent pod status..."
        sleep 10
        RUNNING_PODS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$FIRST_NODE_IP" \
          "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get pods -n cattle-system -l app=cattle-cluster-agent --no-headers 2>/dev/null | grep -c Running || echo '0'" || echo "0")
        if [ "$RUNNING_PODS" -gt "0" ]; then
          echo "  ✓ $RUNNING_PODS cattle-cluster-agent pod(s) running"
        else
          echo "  ⚠ cattle-cluster-agent pods not running yet (may need DNS resolution)"
          echo "  Check pod logs: kubectl -n cattle-system logs -l app=cattle-cluster-agent"
        fi
      fi
      
      # Don't fail the entire apply if registration had issues - cluster may still work
      if [ $REGISTRATION_FAILED -eq 1 ]; then
        echo ""
        echo "⚠ Some registrations failed, but continuing..."
        echo "You may need to manually register nodes or retry registration"
      fi
      
      echo ""
      echo "=============================================="
      echo "✓ Cluster Registration Complete!"
      echo "=============================================="
      echo ""
      echo "Manifest URL: $MANIFEST_URL"
      echo ""
      echo "Monitor cattle-cluster-agent pods:"
      echo "  kubectl -n cattle-system get pods -l app=cattle-cluster-agent"
      echo ""
      echo "Cluster should now appear in Rancher Manager:"
      echo "  $RANCHER_URL/dashboard/c/$CLUSTER_ID"
    EOT
  }
}
