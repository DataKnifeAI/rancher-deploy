locals {
  # Image pull secrets YAML for Palworld operator when using private registry
  palworld_operator_image_pull_secrets = var.palworld_operator_image_pull_secret != "" ? "      imagePullSecrets:\n      - name: ${var.palworld_operator_image_pull_secret}" : ""
}

# ============================================================================
# PALWORLD OPERATOR - NPRD / PRD / POC APPS
# Installs via kubectl apply of kustomize-equivalent manifests (CRD + RBAC + Deployment).
# Does NOT manage PalworldServer game workloads (e.g. game-servers namespace).
# ============================================================================

resource "null_resource" "deploy_palworld_operator_nprd_apps" {
  count = var.install_palworld_operator_nprd ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying Palworld Operator to NPRD Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'PALWORLD_OPERATOR_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/palworld-operator.yaml.tpl", {
  palworld_operator_image = var.palworld_operator_image
  image_pull_secrets      = local.palworld_operator_image_pull_secrets
})}
PALWORLD_OPERATOR_MANIFEST_END

      kubectl create namespace palworld-operator-system --dry-run=client -o yaml | kubectl apply -f -

      if [ -n "${var.palworld_operator_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.palworld_operator_image_pull_secret} -n palworld-operator-system &>/dev/null; then
          if [ -n "${var.palworld_operator_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.palworld_operator_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.palworld_operator_image_pull_secret_file}..."
            jq --arg ns palworld-operator-system \
              'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = $ns | .metadata.name = "${var.palworld_operator_image_pull_secret}"' \
              "${path.module}/../${var.palworld_operator_image_pull_secret_file}" | kubectl apply -f -
          else
            echo "WARNING: Image pull secret ${var.palworld_operator_image_pull_secret} not found in palworld-operator-system. Set palworld_operator_image_pull_secret_file or create the secret manually."
          fi
        else
          echo "✓ Image pull secret ${var.palworld_operator_image_pull_secret} already exists in palworld-operator-system"
        fi
      fi

      kubectl apply --server-side --force-conflicts -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for Palworld operator Deployment..."
      kubectl -n palworld-operator-system rollout status deployment/palworld-operator-controller-manager --timeout=5m || true
      kubectl -n palworld-operator-system get pods,deploy
      echo "✓ Palworld operator deployment complete (nprd-apps)"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      # Leave CRDs (and any PalworldServer CRs) in place; remove controller + namespaced RBAC via namespace delete.
      kubectl delete deployment palworld-operator-controller-manager -n palworld-operator-system --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrolebinding palworld-operator-manager-rolebinding --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrole palworld-operator-manager-role --ignore-not-found 2>/dev/null || true
      kubectl delete namespace palworld-operator-system --timeout=2m 2>/dev/null || true
      echo "✓ Palworld operator removed from nprd-apps (CRD retained)"
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    palworld_operator_image                  = var.palworld_operator_image
    palworld_operator_image_pull_secret      = var.palworld_operator_image_pull_secret
    palworld_operator_image_pull_secret_file = var.palworld_operator_image_pull_secret_file
    template_file                            = filemd5("${path.module}/templates/palworld-operator.yaml.tpl")
  }
}

resource "null_resource" "deploy_palworld_operator_prd_apps" {
  count = var.install_palworld_operator_prd ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying Palworld Operator to PRD Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'PALWORLD_OPERATOR_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/palworld-operator.yaml.tpl", {
  palworld_operator_image = var.palworld_operator_image
  image_pull_secrets      = local.palworld_operator_image_pull_secrets
})}
PALWORLD_OPERATOR_MANIFEST_END

      kubectl create namespace palworld-operator-system --dry-run=client -o yaml | kubectl apply -f -

      if [ -n "${var.palworld_operator_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.palworld_operator_image_pull_secret} -n palworld-operator-system &>/dev/null; then
          if [ -n "${var.palworld_operator_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.palworld_operator_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.palworld_operator_image_pull_secret_file}..."
            jq --arg ns palworld-operator-system \
              'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = $ns | .metadata.name = "${var.palworld_operator_image_pull_secret}"' \
              "${path.module}/../${var.palworld_operator_image_pull_secret_file}" | kubectl apply -f -
          else
            echo "WARNING: Image pull secret ${var.palworld_operator_image_pull_secret} not found in palworld-operator-system. Set palworld_operator_image_pull_secret_file or create the secret manually."
          fi
        else
          echo "✓ Image pull secret ${var.palworld_operator_image_pull_secret} already exists in palworld-operator-system"
        fi
      fi

      kubectl apply --server-side --force-conflicts -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for Palworld operator Deployment..."
      kubectl -n palworld-operator-system rollout status deployment/palworld-operator-controller-manager --timeout=5m || true
      kubectl -n palworld-operator-system get pods,deploy
      echo "✓ Palworld operator deployment complete (prd-apps)"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      # Leave CRDs (and any PalworldServer CRs) in place; remove controller + namespaced RBAC via namespace delete.
      kubectl delete deployment palworld-operator-controller-manager -n palworld-operator-system --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrolebinding palworld-operator-manager-rolebinding --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrole palworld-operator-manager-role --ignore-not-found 2>/dev/null || true
      kubectl delete namespace palworld-operator-system --timeout=2m 2>/dev/null || true
      echo "✓ Palworld operator removed from prd-apps (CRD retained)"
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    palworld_operator_image                  = var.palworld_operator_image
    palworld_operator_image_pull_secret      = var.palworld_operator_image_pull_secret
    palworld_operator_image_pull_secret_file = var.palworld_operator_image_pull_secret_file
    template_file                            = filemd5("${path.module}/templates/palworld-operator.yaml.tpl")
  }
}

resource "null_resource" "deploy_palworld_operator_poc_apps" {
  count = var.install_palworld_operator_poc ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying Palworld Operator to POC Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'PALWORLD_OPERATOR_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/palworld-operator.yaml.tpl", {
  palworld_operator_image = var.palworld_operator_image
  image_pull_secrets      = local.palworld_operator_image_pull_secrets
})}
PALWORLD_OPERATOR_MANIFEST_END

      kubectl create namespace palworld-operator-system --dry-run=client -o yaml | kubectl apply -f -

      if [ -n "${var.palworld_operator_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.palworld_operator_image_pull_secret} -n palworld-operator-system &>/dev/null; then
          if [ -n "${var.palworld_operator_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.palworld_operator_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.palworld_operator_image_pull_secret_file}..."
            jq --arg ns palworld-operator-system \
              'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = $ns | .metadata.name = "${var.palworld_operator_image_pull_secret}"' \
              "${path.module}/../${var.palworld_operator_image_pull_secret_file}" | kubectl apply -f -
          else
            echo "WARNING: Image pull secret ${var.palworld_operator_image_pull_secret} not found in palworld-operator-system. Set palworld_operator_image_pull_secret_file or create the secret manually."
          fi
        else
          echo "✓ Image pull secret ${var.palworld_operator_image_pull_secret} already exists in palworld-operator-system"
        fi
      fi

      kubectl apply --server-side --force-conflicts -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for Palworld operator Deployment..."
      kubectl -n palworld-operator-system rollout status deployment/palworld-operator-controller-manager --timeout=5m || true
      kubectl -n palworld-operator-system get pods,deploy
      echo "✓ Palworld operator deployment complete (poc-apps)"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      # Leave CRDs (and any PalworldServer CRs) in place; remove controller + namespaced RBAC via namespace delete.
      kubectl delete deployment palworld-operator-controller-manager -n palworld-operator-system --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrolebinding palworld-operator-manager-rolebinding --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrole palworld-operator-manager-role --ignore-not-found 2>/dev/null || true
      kubectl delete namespace palworld-operator-system --timeout=2m 2>/dev/null || true
      echo "✓ Palworld operator removed from poc-apps (CRD retained)"
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    palworld_operator_image                  = var.palworld_operator_image
    palworld_operator_image_pull_secret      = var.palworld_operator_image_pull_secret
    palworld_operator_image_pull_secret_file = var.palworld_operator_image_pull_secret_file
    template_file                            = filemd5("${path.module}/templates/palworld-operator.yaml.tpl")
  }
}
