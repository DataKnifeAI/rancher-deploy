# ============================================================================
# DATAKNIFE APP OPERATORS (prd-apps)
# Stoat + game operators (Satisfactory, Terraria, Bedrock, Dragonwilds).
# Palworld remains in palworld_operator.tf. Windrose operator kustomize is broken
# upstream (missing CRD file); windrose-server Deployment is legacy.
# Does NOT manage instance CRs (Stoat / *Server).
# ============================================================================

locals {
  dataknife_operators = {
    stoat-operator = {
      image    = var.stoat_operator_image
      template = "${path.module}/templates/operators/stoat-operator.yaml.tpl"
    }
    satisfactory-operator = {
      image    = var.satisfactory_operator_image
      template = "${path.module}/templates/operators/satisfactory-operator.yaml.tpl"
    }
    terraria-operator = {
      image    = var.terraria_operator_image
      template = "${path.module}/templates/operators/terraria-operator.yaml.tpl"
    }
    bedrock-operator = {
      image    = var.bedrock_operator_image
      template = "${path.module}/templates/operators/bedrock-operator.yaml.tpl"
    }
    dragonwilds-operator = {
      image    = var.dragonwilds_operator_image
      template = "${path.module}/templates/operators/dragonwilds-operator.yaml.tpl"
    }
  }
}

resource "null_resource" "deploy_dataknife_operator_prd_apps" {
  for_each = var.install_dataknife_operators_prd ? local.dataknife_operators : {}

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      OP="${each.key}"
      NS="$${OP}-system"
      IMAGE="${each.value.image}"
      echo "=========================================="
      echo "Deploying $${OP} to prd-apps ($${IMAGE})"
      echo "=========================================="
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi

      kubectl create namespace "$${NS}" --dry-run=client -o yaml | kubectl apply -f -

      if [ -n "${var.dataknife_operator_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.dataknife_operator_image_pull_secret} -n "$${NS}" &>/dev/null; then
          if [ -n "${var.dataknife_operator_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.dataknife_operator_image_pull_secret_file}" ]; then
            jq --arg ns "$${NS}" \
              'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = $ns | .metadata.name = "${var.dataknife_operator_image_pull_secret}"' \
              "${path.module}/../${var.dataknife_operator_image_pull_secret_file}" | kubectl apply -f -
          else
            echo "WARNING: image pull secret ${var.dataknife_operator_image_pull_secret} missing in $${NS}"
          fi
        fi
      fi

      MANIFEST=$(mktemp)
      cat << 'DKAI_OPERATOR_MANIFEST_END' > "$MANIFEST"
${templatefile(each.value.template, {
  operator_image     = each.value.image
  image_pull_secret  = var.dataknife_operator_image_pull_secret
})}
DKAI_OPERATOR_MANIFEST_END

      kubectl apply --server-side --force-conflicts -f "$MANIFEST"
      rm -f "$MANIFEST"

      kubectl -n "$${NS}" rollout status "deployment/$${OP}-controller-manager" --timeout=5m || true
      kubectl -n "$${NS}" get deploy,pods
      echo "✓ $${OP} deployed"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      OP="${each.key}"
      NS="$${OP}-system"
      kubectl delete deployment "$${OP}-controller-manager" -n "$${NS}" --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrolebinding "$${OP}-manager-rolebinding" --ignore-not-found 2>/dev/null || true
      kubectl delete clusterrole "$${OP}-manager-role" --ignore-not-found 2>/dev/null || true
      kubectl delete namespace "$${NS}" --timeout=2m 2>/dev/null || true
      echo "✓ $${OP} removed from prd-apps (CRD retained)"
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    image       = each.value.image
    template    = filemd5(each.value.template)
    pull_secret = var.dataknife_operator_image_pull_secret
  }
}

# Convenience alias for depends_on from stoat-ha-data
resource "null_resource" "deploy_dataknife_operators_prd_apps" {
  count = var.install_dataknife_operators_prd ? 1 : 0

  depends_on = [null_resource.deploy_dataknife_operator_prd_apps]

  triggers = {
    # Roll when any operator image changes
    stoat        = var.stoat_operator_image
    satisfactory = var.satisfactory_operator_image
    terraria     = var.terraria_operator_image
    bedrock      = var.bedrock_operator_image
    dragonwilds  = var.dragonwilds_operator_image
  }
}
