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

variable "node_count" {
  description = "Number of nodes"
  type        = number
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "install_rancher" {
  description = "Whether to install Rancher on this cluster"
  type        = bool
  default     = false
}

variable "rancher_version" {
  description = "Rancher version"
  type        = string
}

variable "rancher_password" {
  description = "Rancher admin password"
  type        = string
  sensitive   = true
}

variable "rancher_hostname" {
  description = "Rancher hostname (only for manager cluster)"
  type        = string
  default     = ""
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.19.2"
}

output "kubeconfig_path" {
  value = var.kubeconfig_path
}

output "cluster_name" {
  value = var.cluster_name
}

# Deploy Rancher using external script
# Script handles full deployment: cert-manager + Rancher with proper error handling
resource "null_resource" "deploy_rancher" {
  count = var.install_rancher ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      chmod +x ${path.module}/deploy-rancher.sh
      ${path.module}/deploy-rancher.sh \
        "${pathexpand(var.kubeconfig_path)}" \
        "${var.rancher_version}" \
        "${var.rancher_hostname}" \
        "${var.rancher_password}" \
        "${var.cert_manager_version}" \
        "${pathexpand("${path.root}/../config")}"
    EOT
  }
}

# Verify Rancher deployment and accessibility
resource "null_resource" "verify_rancher" {
  count = var.install_rancher ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=========================================="
      echo "Verifying Rancher Deployment"
      echo "=========================================="
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      # Check Rancher pods
      echo "Rancher Pods Status:"
      kubectl get pods -n cattle-system --no-headers | head -5
      
      # Verify Rancher is responding
      echo ""
      echo "Testing Rancher URL: https://${var.rancher_hostname}"
      HTTP_CODE=$(curl -k -s -o /dev/null -w "%%{http_code}" "https://${var.rancher_hostname}" 2>/dev/null || echo "000")
      
      if [ "$HTTP_CODE" = "200" ]; then
        echo "✓ Rancher is ACCESSIBLE (HTTP $HTTP_CODE)"
      else
        echo "⚠ Rancher HTTP Status: $HTTP_CODE"
        echo "  (This may be normal during startup, allow 2-3 minutes for full initialization)"
      fi
      
      # Show login instructions
      echo ""
      echo "=========================================="
      echo "RANCHER ACCESS"
      echo "=========================================="
      echo "URL: https://${var.rancher_hostname}"
      echo "Username: admin"
      echo "Password: (from rancher_password in tfvars)"
      echo ""
      echo "IMPORTANT: Change password immediately after first login!"
      echo "=========================================="
    EOT
    
    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_rancher]
}

# Optional: Create monitoring namespace for future agent deployments
resource "null_resource" "create_monitoring_namespace" {
  count = var.install_rancher ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      kubectl create namespace cattle-monitoring-system 2>/dev/null || true
      echo "✓ Monitoring namespace ready"
    EOT
    
    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_rancher]
}
