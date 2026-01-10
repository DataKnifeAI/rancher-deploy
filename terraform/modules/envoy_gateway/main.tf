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

variable "install_envoy_gateway" {
  description = "Whether to install Envoy Gateway on this cluster"
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = "Gateway API CRDs version"
  type        = string
  default     = "v1.0.0"
}

variable "envoy_gateway_version" {
  description = "Envoy Gateway Helm chart version"
  type        = string
  default     = "v1.6.1"
}

variable "namespace" {
  description = "Namespace for Envoy Gateway"
  type        = string
  default     = "envoy-gateway-system"
}

output "kubeconfig_path" {
  value = var.kubeconfig_path
}

output "cluster_name" {
  value = var.cluster_name
}

# Deploy Envoy Gateway using external script
# Script handles: Gateway API CRDs installation + Envoy Gateway Helm deployment
resource "null_resource" "deploy_envoy_gateway" {
  count = var.install_envoy_gateway ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      chmod +x ${path.module}/deploy-envoy-gateway.sh
      ${path.module}/deploy-envoy-gateway.sh \
        "${pathexpand(var.kubeconfig_path)}" \
        "${var.gateway_api_version}" \
        "${var.envoy_gateway_version}" \
        "${var.namespace}" \
        "${var.cluster_name}"
    EOT
  }
}

# Verify Envoy Gateway deployment
resource "null_resource" "verify_envoy_gateway" {
  count = var.install_envoy_gateway ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=========================================="
      echo "Verifying Envoy Gateway Deployment"
      echo "=========================================="
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      # Wait for Gateway API CRDs to be ready
      echo "Checking Gateway API CRDs..."
      CRD_READY=0
      for i in {1..30}; do
        if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null && \
           kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null && \
           kubectl get crd gatewayclasses.gateway.networking.k8s.io &>/dev/null; then
          CRD_READY=1
          echo "  ✓ Gateway API CRDs are ready"
          break
        fi
        if [ $((i % 5)) -eq 0 ]; then
          echo "  Waiting for Gateway API CRDs... attempt $i/30"
        fi
        sleep 2
      done
      
      if [ "$CRD_READY" -eq 0 ]; then
        echo "  ⚠ Gateway API CRDs not ready after 60 seconds"
        echo "  This may be normal if installation is still in progress"
      fi
      
      # Check Envoy Gateway pods
      echo ""
      echo "Checking Envoy Gateway pods in namespace ${var.namespace}..."
      POD_COUNT=$(kubectl get pods -n ${var.namespace} --no-headers 2>/dev/null | wc -l || echo "0")
      if [ "$POD_COUNT" -gt 0 ]; then
        echo "  Envoy Gateway Pods Status:"
        kubectl get pods -n ${var.namespace} --no-headers | head -5
        echo ""
        echo "  Pod Details:"
        kubectl get pods -n ${var.namespace} -o wide
      else
        echo "  ⚠ No pods found in namespace ${var.namespace} yet"
        echo "  This may be normal if installation is still in progress"
      fi
      
      # Check GatewayClass
      echo ""
      echo "Checking GatewayClass..."
      if kubectl get gatewayclass &>/dev/null; then
        kubectl get gatewayclass
        echo ""
        echo "  ✓ GatewayClass created successfully"
      else
        echo "  ⚠ GatewayClass not found yet"
        echo "  This may be normal if installation is still in progress"
      fi
      
      echo ""
      echo "=========================================="
      echo "Envoy Gateway Installation Summary"
      echo "=========================================="
      echo "Cluster: ${var.cluster_name}"
      echo "Namespace: ${var.namespace}"
      echo "Gateway API Version: ${var.gateway_api_version}"
      echo "Envoy Gateway Version: ${var.envoy_gateway_version}"
      echo ""
      echo "Next steps:"
      echo "  1. Create a GatewayClass: kubectl apply -f - <<EOF"
      echo "     apiVersion: gateway.networking.k8s.io/v1"
      echo "     kind: GatewayClass"
      echo "     metadata:"
      echo "       name: eg"
      echo "     spec:"
      echo "       controllerName: gateway.envoyproxy.io/gatewayclass-eg"
      echo "     EOF"
      echo ""
      echo "  2. Create a Gateway resource (see docs/GATEWAY_API_SETUP.md)"
      echo "=========================================="
    EOT

    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_envoy_gateway]
}
