# ============================================================================
# SHARED DATA OPERATORS (Stoat HA / reusable)
# Percona MongoDB, OpsTree Redis, RabbitMQ Cluster Operator.
# Install on apps clusters that host Stoat (or other workloads needing these CRDs).
# Instance CRs (stoat-mongo / stoat-redis / stoat-rabbit) are optional — see
# install_stoat_ha_data_* and templates/stoat-ha-data/.
# ============================================================================

resource "null_resource" "deploy_shared_data_operators_prd_apps" {
  count = var.install_shared_data_operators_prd ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      export PSMDB_OPERATOR_CHART_VERSION="${var.psmdb_operator_chart_version}"
      export PSMDB_OPERATOR_CRDS_VERSION="${var.psmdb_operator_crds_version}"
      export REDIS_OPERATOR_CHART_VERSION="${var.redis_operator_chart_version}"
      export RABBITMQ_CLUSTER_OPERATOR_VERSION="${var.rabbitmq_cluster_operator_version}"
      "${path.module}/../scripts/install-shared-data-operators.sh" prd-apps
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    script = filemd5("${path.module}/../scripts/install-shared-data-operators.sh")
    psmdb  = var.psmdb_operator_chart_version
    redis  = var.redis_operator_chart_version
    rabbit = var.rabbitmq_cluster_operator_version
  }
}

resource "null_resource" "deploy_stoat_ha_data_prd_apps" {
  count = var.install_stoat_ha_data_prd ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      echo "Applying Stoat HA data-plane CRs (mongo/redis/rabbit) into namespace stoat..."
      kubectl create namespace stoat --dry-run=client -o yaml | kubectl apply -f -
      kubectl apply -f "${path.module}/templates/stoat-ha-data/"
      echo "✓ stoat-ha-data applied (ensure user/URI secrets exist — see stoat-operator/deploy/ha/README.md)"
      kubectl -n stoat get perconaservermongodb,redisreplication,redissentinel,rabbitmqcluster 2>/dev/null || true
    EOT
  }

  depends_on = [
    null_resource.deploy_shared_data_operators_prd_apps,
    null_resource.deploy_dataknife_operators_prd_apps
  ]

  triggers = {
    mongo  = filemd5("${path.module}/templates/stoat-ha-data/mongo.yaml")
    redis  = filemd5("${path.module}/templates/stoat-ha-data/redis.yaml")
    rabbit = filemd5("${path.module}/templates/stoat-ha-data/rabbitmq.yaml")
  }
}
