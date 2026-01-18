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

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "install_kube_vip" {
  description = "Whether to install Kube-VIP on this cluster"
  type        = bool
  default     = true
}

variable "kube_vip_version" {
  description = "Kube-VIP version (latest: v1.0.3, see https://github.com/kube-vip/kube-vip/releases)"
  type        = string
  default     = "v1.0.3"
}

variable "namespace" {
  description = "Namespace for Kube-VIP"
  type        = string
  default     = "kube-vip"
}

variable "ip_pool_addresses" {
  description = "IP address range for Kube-VIP LoadBalancer services (e.g., '192.168.14.150-192.168.14.251')"
  type        = string
  default     = ""
}

output "kubeconfig_path" {
  value = var.kubeconfig_path
}

output "cluster_name" {
  value = var.cluster_name
}

# Deploy Kube-VIP using external script
# Script handles: Kube-VIP installation + IP pool configuration
resource "null_resource" "deploy_kube_vip" {
  count = var.install_kube_vip ? 1 : 0

  triggers = {
    # Trigger re-deployment when any of these change
    ip_pool_addresses = var.ip_pool_addresses
    kube_vip_version  = var.kube_vip_version
    cluster_name      = var.cluster_name
    kubeconfig_path   = var.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      chmod +x ${path.module}/deploy-kube-vip.sh
      ${path.module}/deploy-kube-vip.sh \
        "${pathexpand(var.kubeconfig_path)}" \
        "${var.kube_vip_version}" \
        "${var.namespace}" \
        "${var.cluster_name}" \
        "${var.ip_pool_addresses}"
    EOT
  }
}

# Verify Kube-VIP deployment
resource "null_resource" "verify_kube_vip" {
  count = var.install_kube_vip ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=========================================="
      echo "Verifying Kube-VIP Deployment"
      echo "=========================================="
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      # Check Kube-VIP pods
      echo ""
      echo "Checking Kube-VIP pods in namespace ${var.namespace}..."
      POD_COUNT=$(kubectl get pods -n ${var.namespace} --no-headers 2>/dev/null | wc -l || echo "0")
      if [ "$POD_COUNT" -gt 0 ]; then
        echo "  Kube-VIP Pods Status:"
        kubectl get pods -n ${var.namespace} --no-headers | head -5
        echo ""
        echo "  Pod Details:"
        kubectl get pods -n ${var.namespace} -o wide
      else
        echo "  ⚠ No pods found in namespace ${var.namespace} yet"
        echo "  This may be normal if installation is still in progress"
      fi
      
      # Check ConfigMap if configured
      if [ -n "${var.ip_pool_addresses}" ]; then
        echo ""
        echo "Checking Kube-VIP ConfigMap..."
        if kubectl get configmap kubevip -n ${var.namespace} &>/dev/null; then
          kubectl get configmap kubevip -n ${var.namespace} -o yaml | grep -A 5 "range"
          echo ""
          echo "  ✓ Kube-VIP ConfigMap configured"
        else
          echo "  ⚠ ConfigMap not found yet"
          echo "  This may be normal if installation is still in progress"
        fi
      fi
      
      echo ""
      echo "=========================================="
      echo "Kube-VIP Installation Summary"
      echo "=========================================="
      echo "Cluster: ${var.cluster_name}"
      echo "Namespace: ${var.namespace}"
      echo "Kube-VIP Version: ${var.kube_vip_version}"
      if [ -n "${var.ip_pool_addresses}" ]; then
        echo "IP Pool: ${var.ip_pool_addresses}"
      fi
      echo ""
      echo "Next steps:"
      echo "  1. Verify installation:"
      echo "     kubectl get pods -n ${var.namespace}"
      echo "     kubectl get configmap kubevip -n ${var.namespace}"
      echo ""
      echo "  2. Configure services to use LoadBalancer type"
      echo "=========================================="
    EOT

    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_kube_vip]
}
