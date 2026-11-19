# DataKnife operators (prd-apps)

Terraform installs **controllers + CRDs** on **prd-apps**. It does **not** create
game/`Stoat` instance CRs (those stay kubectl / GitOps).

## Shared data operators

Flag: `install_shared_data_operators_prd` (default `true`).

| Operator | Chart / release | Namespace |
|----------|-----------------|-----------|
| Percona PSMDB | `percona/psmdb-operator` 1.23.2 (+ CRDs 1.23.1) | `percona-system` |
| OpsTree Redis | `ot-helm/redis-operator` 0.27.0 | `redis-operator` |
| RabbitMQ Cluster | GitHub release `v2.23.3` | `rabbitmq-system` |

Script: [`scripts/install-shared-data-operators.sh`](../scripts/install-shared-data-operators.sh).

RabbitMQ needs **cert-manager** (already on apps clusters).

### Stoat HA instance CRs (optional)

Flag: `install_stoat_ha_data_prd` (default `false`).

Applies vendored manifests under `terraform/templates/stoat-ha-data/` into
namespace `stoat`. **User secrets** (`stoat-ha-mongo-users`, app passwords, URI
secrets) are still manual — see
[stoat-operator/deploy/ha/README.md](https://github.com/DataKnifeAI/stoat-operator/blob/main/deploy/ha/README.md).

## App operators

Flag: `install_dataknife_operators_prd` (default `true`).

| Operator | Default image pin (matches live prd as of 2026-11-19) |
|----------|--------------------------------------------------------|
| stoat | `harbor…/stoat-operator:9bdea64` |
| satisfactory | `…/satisfactory-operator:v0.1.0` |
| terraria | `…/terraria-operator:phase3-parity` |
| bedrock | `…/bedrock-operator:joinfix-20261117084844` |
| dragonwilds | `…/dragonwilds-operator:v0.2.3` |
| palworld | separate `install_palworld_operator_prd` |

Manifests: `terraform/templates/operators/*.yaml.tpl` (kustomize render with
`${operator_image}`). Re-render after operator API changes:

```bash
kubectl kustomize ../stoat-operator/config/default | \
  # replace harbor image → ${operator_image}, escape other $ for templatefile
  …
```

**Windrose:** operator kustomize is broken (missing CRD file); `windrose-server`
Deployment remains legacy — not managed here.

## Apply

```bash
# After merging and setting tfvars (Harbor secret path):
cd terraform
terraform apply -refresh=false \
  -target=null_resource.deploy_shared_data_operators_prd_apps \
  -target=null_resource.deploy_dataknife_operator_prd_apps
```

Or run the scripts against an existing kubeconfig:

```bash
export KUBECONFIG=$HOME/.kube/prd-apps-rke2.yaml   # or prd-apps.yaml
./scripts/install-shared-data-operators.sh prd-apps
IMAGE_PULL_SECRET=harbor-registry-secret \
  IMAGE_PULL_SECRET_FILE=config/harbor-registry-secret.yaml \
  ./scripts/install-dataknife-operators.sh prd-apps
```
