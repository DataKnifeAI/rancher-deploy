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

variable "install_metallb" {
  description = "Whether to install MetalLB on this cluster"
  type        = bool
  default     = true
}

variable "metallb_version" {
  description = "MetalLB version (latest: v0.15.3, see https://metallb.universe.tf/release-notes/)"
  type        = string
  default     = "v0.15.3"
}

variable "namespace" {
  description = "Namespace for MetalLB"
  type        = string
  default     = "metallb-system"
}

variable "ip_pool_addresses" {
  description = "IP address pool for MetalLB LoadBalancer services (e.g., '192.168.1.200-192.168.1.210')"
  type        = string
  default     = ""
}

output "kubeconfig_path" {
  value = var.kubeconfig_path
}

output "cluster_name" {
  value = var.cluster_name
}

# Deploy MetalLB using external script
# Script handles: MetalLB installation + IP pool configuration
resource "null_resource" "deploy_metallb" {
  count = var.install_metallb ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      chmod +x ${path.module}/deploy-metallb.sh
      ${path.module}/deploy-metallb.sh \
        "${pathexpand(var.kubeconfig_path)}" \
        "${var.metallb_version}" \
        "${var.namespace}" \
        "${var.cluster_name}" \
        "${var.ip_pool_addresses}"
    EOT
  }
}

# Verify MetalLB deployment
resource "null_resource" "verify_metallb" {
  count = var.install_metallb ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=========================================="
      echo "Verifying MetalLB Deployment"
      echo "=========================================="
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      # Wait for MetalLB CRDs to be ready
      echo "Checking MetalLB CRDs..."
      CRD_READY=0
      for i in {1..30}; do
        if kubectl get crd ipaddresspools.metallb.io &>/dev/null && \
           kubectl get crd l2advertisements.metallb.io &>/dev/null; then
          CRD_READY=1
          echo "  ✓ MetalLB CRDs are ready"
          break
        fi
        if [ $((i % 5)) -eq 0 ]; then
          echo "  Waiting for MetalLB CRDs... attempt $i/30"
        fi
        sleep 2
      done
      
      if [ "$CRD_READY" -eq 0 ]; then
        echo "  ⚠ MetalLB CRDs not ready after 60 seconds"
        echo "  This may be normal if installation is still in progress"
      fi
      
      # Check MetalLB pods
      echo ""
      echo "Checking MetalLB pods in namespace ${var.namespace}..."
      POD_COUNT=$(kubectl get pods -n ${var.namespace} --no-headers 2>/dev/null | wc -l || echo "0")
      if [ "$POD_COUNT" -gt 0 ]; then
        echo "  MetalLB Pods Status:"
        kubectl get pods -n ${var.namespace} --no-headers | head -5
        echo ""
        echo "  Pod Details:"
        kubectl get pods -n ${var.namespace} -o wide
      else
        echo "  ⚠ No pods found in namespace ${var.namespace} yet"
        echo "  This may be normal if installation is still in progress"
      fi
      
      # Check IP pool if configured
      if [ -n "${var.ip_pool_addresses}" ]; then
        echo ""
        echo "Checking IP address pool..."
        if kubectl get ipaddresspool -n ${var.namespace} &>/dev/null; then
          kubectl get ipaddresspool -n ${var.namespace}
          echo ""
          echo "  ✓ IP address pool configured"
        else
          echo "  ⚠ IP address pool not found yet"
          echo "  This may be normal if installation is still in progress"
        fi
      fi
      
      echo ""
      echo "=========================================="
      echo "MetalLB Installation Summary"
      echo "=========================================="
      echo "Cluster: ${var.cluster_name}"
      echo "Namespace: ${var.namespace}"
      echo "MetalLB Version: ${var.metallb_version}"
      if [ -n "${var.ip_pool_addresses}" ]; then
        echo "IP Pool: ${var.ip_pool_addresses}"
      fi
      echo ""
      echo "Next steps:"
      echo "  1. Verify installation:"
      echo "     kubectl get pods -n ${var.namespace}"
      echo "     kubectl get ipaddresspool -n ${var.namespace}"
      echo ""
      echo "  2. Configure services to use LoadBalancer type (see docs/METALLB_SETUP.md)"
      echo "=========================================="
    EOT

    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_metallb]
}
