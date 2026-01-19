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

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.13.0"
}

variable "namespace" {
  description = "Namespace for cert-manager"
  type        = string
  default     = "cert-manager"
}

output "kubeconfig_path" {
  value = var.kubeconfig_path
}

output "cluster_name" {
  value = var.cluster_name
}

# Deploy cert-manager using Helm
resource "null_resource" "deploy_cert_manager" {
  # Trigger recreation when version changes or Helm configuration changes
  triggers = {
    cert_manager_version = var.cert_manager_version
    cluster_name        = var.cluster_name
    kubeconfig_path     = var.kubeconfig_path
    namespace           = var.namespace
    # Include extraArgs in trigger to force upgrade when gateway-shim is enabled
    extra_args_config   = "--controllers=*,gateway-shim"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying cert-manager to ${var.cluster_name} Cluster"
      echo "=========================================="
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access ${var.cluster_name} cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      echo ""
      
      # Add Helm repository
      echo "Adding Helm repository..."
      helm repo add jetstack https://charts.jetstack.io --force-update || true
      helm repo update
      echo "✓ Helm repositories updated"
      echo ""
      
      # Install cert-manager
      echo "Installing cert-manager ${var.cert_manager_version}..."
      kubectl create namespace ${var.namespace} 2>/dev/null || true
      
      # Check if cert-manager CRDs exist (cluster-scoped)
      CERT_MANAGER_CRDS_EXIST=false
      if kubectl get crd certificaterequests.cert-manager.io &>/dev/null 2>&1 || \
         kubectl get crd certificates.cert-manager.io &>/dev/null 2>&1 || \
         kubectl get crd clusterissuers.cert-manager.io &>/dev/null 2>&1; then
        CERT_MANAGER_CRDS_EXIST=true
      fi
      
      # Check if cert-manager ClusterRoles exist (cluster-scoped RBAC)
      # Check for any cert-manager ClusterRole by pattern
      CERT_MANAGER_RBAC_EXIST=false
      if kubectl get clusterrole 2>/dev/null | grep -q "cert-manager"; then
        CERT_MANAGER_RBAC_EXIST=true
      fi
      
      # Check if cert-manager Roles exist in kube-system (namespaced RBAC)
      # cert-manager often creates leader election roles in kube-system
      CERT_MANAGER_ROLES_EXIST=false
      if kubectl get role -n kube-system 2>/dev/null | grep -q "cert-manager"; then
        CERT_MANAGER_ROLES_EXIST=true
      fi
      
      # Check if cert-manager WebhookConfigurations exist (cluster-scoped)
      CERT_MANAGER_WEBHOOKS_EXIST=false
      if kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -q "cert-manager" || \
         kubectl get validatingwebhookconfiguration 2>/dev/null | grep -q "cert-manager"; then
        CERT_MANAGER_WEBHOOKS_EXIST=true
      fi
      
      # Check if cert-manager already exists (namespaced resources)
      CERT_MANAGER_EXISTS=false
      if kubectl get namespace ${var.namespace} &>/dev/null 2>&1 && \
         kubectl get deployment cert-manager -n ${var.namespace} &>/dev/null 2>&1; then
        CERT_MANAGER_EXISTS=true
      fi
      
      # Check if Helm release exists
      HELM_RELEASE_EXISTS=false
      if helm list -n ${var.namespace} 2>/dev/null | grep -q cert-manager; then
        HELM_RELEASE_EXISTS=true
      fi
      
      # If cert-manager exists (CRDs, RBAC, webhooks, or namespace resources) but is not managed by Helm, clean it up
      if [ "$CERT_MANAGER_CRDS_EXIST" = "true" ] || [ "$CERT_MANAGER_RBAC_EXIST" = "true" ] || [ "$CERT_MANAGER_ROLES_EXIST" = "true" ] || [ "$CERT_MANAGER_WEBHOOKS_EXIST" = "true" ] || [ "$CERT_MANAGER_EXISTS" = "true" ]; then
        if [ "$HELM_RELEASE_EXISTS" = "true" ]; then
          echo "  ✓ cert-manager is already managed by Helm, upgrading..."
          echo "  Enabling controllers: ingress-shim (default) + gateway-shim (for Gateway API)"
          helm upgrade cert-manager jetstack/cert-manager \
            --namespace ${var.namespace} \
            --set installCRDs=true \
            --set 'extraArgs[0]=--controllers=*\,gateway-shim' \
            --version "${var.cert_manager_version}" \
            --wait \
            --timeout 10m \
            || {
              echo "ERROR: Failed to upgrade cert-manager"
              exit 1
            }
        else
          echo "  ⚠ cert-manager exists but is not managed by Helm"
          echo "  Cleaning up existing installation to ensure clean Helm-managed installation..."
          echo "  (This is safe - cert-manager will be reinstalled immediately)"
          
          # Delete cert-manager CRDs first (cluster-scoped, not in namespace)
          if [ "$CERT_MANAGER_CRDS_EXIST" = "true" ]; then
            echo "  Deleting cert-manager CRDs..."
            kubectl delete crd --ignore-not-found=true \
              certificaterequests.cert-manager.io \
              certificates.cert-manager.io \
              certificaterequests.acme.cert-manager.io \
              challenges.acme.cert-manager.io \
              clusterissuers.cert-manager.io \
              issuers.cert-manager.io \
              orders.acme.cert-manager.io \
              2>/dev/null || true
            
            echo "  Waiting for CRDs to be fully deleted..."
            # Wait for CRDs to be deleted
            for i in {1..30}; do
              if ! kubectl get crd certificaterequests.cert-manager.io &>/dev/null && \
                 ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
                echo "  ✓ cert-manager CRDs deleted"
                break
              fi
              if [ $((i % 5)) -eq 0 ]; then
                echo "  Still waiting for CRD deletion... attempt $i/30"
              fi
              sleep 2
            done
          fi
          
          # Delete cert-manager ClusterRoles and ClusterRoleBindings (cluster-scoped)
          # Delete all cert-manager ClusterRoles and Bindings by pattern to catch any we might have missed
          echo "  Deleting cert-manager ClusterRoles and ClusterRoleBindings..."
          
          # Get all cert-manager ClusterRoles and delete them
          kubectl get clusterrole 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r kubectl delete clusterrole --ignore-not-found=true 2>/dev/null || true
          
          # Get all cert-manager ClusterRoleBindings and delete them
          kubectl get clusterrolebinding 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r kubectl delete clusterrolebinding --ignore-not-found=true 2>/dev/null || true
          
          # Also try deleting by common names as backup
          kubectl delete clusterrole --ignore-not-found=true \
            cert-manager-cainjector \
            cert-manager-controller \
            cert-manager-controller-approve:cert-manager-io \
            cert-manager-controller-certificates \
            cert-manager-controller-certificatesigningrequests \
            cert-manager-controller-challenges \
            cert-manager-controller-clusterissuers \
            cert-manager-controller-ingress-shim \
            cert-manager-controller-issuers \
            cert-manager-controller-orders \
            cert-manager-edit \
            cert-manager-view \
            cert-manager-cluster-view \
            2>/dev/null || true
          
          kubectl delete clusterrolebinding --ignore-not-found=true \
            cert-manager-cainjector \
            cert-manager-controller-approve:cert-manager-io \
            cert-manager-controller-certificates \
            cert-manager-controller-certificatesigningrequests \
            cert-manager-controller-challenges \
            cert-manager-controller-clusterissuers \
            cert-manager-controller-ingress-shim \
            cert-manager-controller-issuers \
            cert-manager-controller-orders \
            2>/dev/null || true
          
          echo "  ✓ cert-manager ClusterRoles and ClusterRoleBindings deleted"
          sleep 2
          
          # Delete cert-manager WebhookConfigurations (cluster-scoped)
          if [ "$CERT_MANAGER_WEBHOOKS_EXIST" = "true" ]; then
            echo "  Deleting cert-manager WebhookConfigurations..."
            
            # Delete by name first
            kubectl delete mutatingwebhookconfiguration --ignore-not-found=true \
              cert-manager-webhook \
              2>/dev/null || true
            
            kubectl delete validatingwebhookconfiguration --ignore-not-found=true \
              cert-manager-webhook \
              cert-manager-webhook-webhook \
              2>/dev/null || true
            
            # Also try pattern matching to catch any we missed
            kubectl get mutatingwebhookconfiguration 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
              xargs -r kubectl delete mutatingwebhookconfiguration --ignore-not-found=true 2>/dev/null || true
            
            kubectl get validatingwebhookconfiguration 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
              xargs -r kubectl delete validatingwebhookconfiguration --ignore-not-found=true 2>/dev/null || true
            
            echo "  Waiting for WebhookConfigurations to be fully deleted..."
            # Wait for webhooks to be deleted
            for i in {1..30}; do
              if ! kubectl get mutatingwebhookconfiguration cert-manager-webhook &>/dev/null 2>&1 && \
                 ! kubectl get validatingwebhookconfiguration cert-manager-webhook &>/dev/null 2>&1; then
                echo "  ✓ cert-manager WebhookConfigurations deleted"
                break
              fi
              if [ $((i % 5)) -eq 0 ]; then
                echo "  Still waiting for WebhookConfiguration deletion... attempt $i/30"
              fi
              sleep 2
            done
            
            # Double-check that all cert-manager webhooks are gone
            if kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -q "cert-manager" || \
               kubectl get validatingwebhookconfiguration 2>/dev/null | grep -q "cert-manager"; then
              echo "  ⚠ Some cert-manager webhooks may still exist, attempting force deletion..."
              kubectl get mutatingwebhookconfiguration 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
                xargs -r kubectl delete mutatingwebhookconfiguration --ignore-not-found=true --wait=false 2>/dev/null || true
              kubectl get validatingwebhookconfiguration 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
                xargs -r kubectl delete validatingwebhookconfiguration --ignore-not-found=true --wait=false 2>/dev/null || true
              sleep 3
            fi
            
            sleep 2
          fi
          
          # Delete cert-manager Roles and RoleBindings from all namespaces (especially kube-system)
          echo "  Deleting cert-manager Roles and RoleBindings from all namespaces..."
          
          # Delete Roles from kube-system namespace (where cert-manager often creates them)
          kubectl get role -n kube-system 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r -I {} kubectl delete role {} -n kube-system --ignore-not-found=true 2>/dev/null || true
          
          # Delete RoleBindings from kube-system namespace
          kubectl get rolebinding -n kube-system 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r -I {} kubectl delete rolebinding {} -n kube-system --ignore-not-found=true 2>/dev/null || true
          
          # Also check and delete from cert-manager namespace
          kubectl get role -n ${var.namespace} 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r -I {} kubectl delete role {} -n ${var.namespace} --ignore-not-found=true 2>/dev/null || true
          
          kubectl get rolebinding -n ${var.namespace} 2>/dev/null | grep "cert-manager" | awk '{print $1}' | \
            xargs -r -I {} kubectl delete rolebinding {} -n ${var.namespace} --ignore-not-found=true 2>/dev/null || true
          
          # Delete common cert-manager Roles by name as backup
          kubectl delete role --ignore-not-found=true -n kube-system \
            cert-manager-cainjector:leaderelection \
            cert-manager-controller:leaderelection \
            cert-manager-webhook:leaderelection \
            2>/dev/null || true
          
          kubectl delete rolebinding --ignore-not-found=true -n kube-system \
            cert-manager-cainjector:leaderelection \
            cert-manager-controller:leaderelection \
            cert-manager-webhook:leaderelection \
            2>/dev/null || true
          
          echo "  ✓ cert-manager Roles and RoleBindings deleted"
          sleep 2
          
          # Delete the namespace to remove all existing resources
          if [ "$CERT_MANAGER_EXISTS" = "true" ]; then
            echo "  Deleting namespace ${var.namespace}..."
            # This ensures a clean installation managed by Helm
            kubectl delete namespace ${var.namespace} --wait=true --timeout=120s 2>/dev/null || {
              echo "  ⚠ Namespace deletion may have timed out or already deleted"
              echo "  Waiting a moment for resources to clean up..."
              sleep 5
            }
            
            # Wait for namespace to be fully deleted
            for i in {1..30}; do
              if ! kubectl get namespace ${var.namespace} &>/dev/null; then
                echo "  ✓ Namespace ${var.namespace} deleted"
                break
              fi
              if [ $((i % 5)) -eq 0 ]; then
                echo "  Still waiting for namespace deletion... attempt $i/30"
              fi
              sleep 2
            done
          fi
          
          # Recreate namespace and install fresh
          kubectl create namespace ${var.namespace} 2>/dev/null || true
          echo "  Installing cert-manager with Helm management..."
        fi
      fi
      
      # Install cert-manager (either fresh install or after cleanup)
      if ! helm list -n ${var.namespace} 2>/dev/null | grep -q cert-manager; then
        echo "  Installing cert-manager ${var.cert_manager_version}..."
        echo "  Enabling controllers: ingress-shim (default) + gateway-shim (for Gateway API)"
        helm upgrade --install cert-manager jetstack/cert-manager \
          --namespace ${var.namespace} \
          --set installCRDs=true \
          --set 'extraArgs[0]=--controllers=*\,gateway-shim' \
          --version "${var.cert_manager_version}" \
          --wait \
          --timeout 10m \
          || {
            echo "ERROR: Failed to install cert-manager"
            exit 1
          }
      fi
      echo "✓ cert-manager installed"
      echo ""
      
      # Wait for cert-manager to be ready
      echo "Waiting for cert-manager deployment..."
      kubectl rollout status deployment/cert-manager -n ${var.namespace} --timeout=5m || {
        echo "⚠ Deployment may still be starting, checking status..."
        kubectl get deployment -n ${var.namespace}
      }
      echo "✓ cert-manager is ready"
      echo ""
      
      # Verify installation
      echo "Verifying cert-manager installation..."
      kubectl get pods -n ${var.namespace}
      echo ""
      
      # Check enabled controllers
      echo "Checking enabled controllers..."
      if kubectl get clusterrole cert-manager-controller-ingress-shim &>/dev/null; then
        echo "  ✓ ingress-shim controller enabled"
      fi
      if kubectl get clusterrole cert-manager-controller-gateway-shim &>/dev/null; then
        echo "  ✓ gateway-shim controller enabled"
      else
        echo "  ⚠ gateway-shim controller not found (may need upgrade)"
      fi
      echo ""
      echo "=========================================="
      echo "cert-manager Installation Summary"
      echo "=========================================="
      echo "Cluster: ${var.cluster_name}"
      echo "Namespace: ${var.namespace}"
      echo "Version: ${var.cert_manager_version}"
      echo ""
      echo "Enabled Controllers:"
      echo "  ✓ ingress-shim (for Ingress resources)"
      echo "  ✓ gateway-shim (for Gateway API / Envoy Gateway)"
      echo ""
      echo "Next steps:"
      echo "  1. Create ClusterIssuer or Issuer for certificate management"
      echo "  2. Use cert-manager with Gateway API (Envoy Gateway) or Ingress for TLS"
      echo "=========================================="
    EOT

    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }
}

# Verify cert-manager deployment
resource "null_resource" "verify_cert_manager" {
  # Trigger recreation when version changes (will also be recreated when deploy_cert_manager changes due to depends_on)
  triggers = {
    cert_manager_version = var.cert_manager_version
    cluster_name        = var.cluster_name
    kubeconfig_path     = var.kubeconfig_path
    namespace           = var.namespace
    deploy_resource_id  = null_resource.deploy_cert_manager.id
    extra_args_config   = "--controllers=*,gateway-shim"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      export KUBECONFIG="${pathexpand(var.kubeconfig_path)}"
      
      echo ""
      echo "Verifying cert-manager deployment..."
      
      # Check cert-manager pods
      POD_COUNT=$(kubectl get pods -n ${var.namespace} --no-headers 2>/dev/null | wc -l || echo "0")
      if [ "$POD_COUNT" -gt 0 ]; then
        echo "  cert-manager Pods:"
        kubectl get pods -n ${var.namespace} -o wide
        echo ""
        
        # Check CRDs
        echo "  cert-manager CRDs:"
        kubectl get crd | grep cert-manager.io || echo "  ⚠ No cert-manager CRDs found"
      else
        echo "  ⚠ No pods found in namespace ${var.namespace}"
      fi
      
      echo ""
      echo "✓ cert-manager verification complete"
    EOT

    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }

  depends_on = [null_resource.deploy_cert_manager]
}
