# Changelog

All notable changes to Rancher Deploy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Repo defaults + **live window completed 2026-11-20/21**: **Rancher** `v2.15.2` → **`v2.15.3`**, **RKE2** `v1.36.2+rke2r1` → **`v1.36.6+rke2r1`** (31/31), **cert-manager** → **`v1.21.3`**, **Envoy Gateway** `v1.9.2` → **`v1.9.4`**, **CloudNativePG** `1.30.1` → **`1.30.2`**. See [docs/UPGRADE_PLAN.md](docs/UPGRADE_PLAN.md#next-wave-reviewed-2026-11-20)
- Downstream registration `rancher_token_file` uses `${abspath("${path.root}/../config")}/.rancher-api-token` instead of a hard-coded `/home/lee/git/...` path
- kube-vip deploy script ClusterRole now includes `endpointslices` / `endpoints` (needed by v1.3.x); **default pin stays `v1.0.3`**

### Fixed
- Hard-coded Rancher API token path in `terraform/main.tf` registration modules

### Known issues
- Terraform Rancher API token still **expired** (admin password rotated past bootstrap secret) — create a fresh token in the UI and write `config/.rancher-api-token` before any `register_downstream_cluster` apply
- **kube-vip `v1.3.2` blocked**: with control-plane-only DaemonSet affinity, `externalTrafficPolicy=Local` services lose their VIP when endpoints are only on workers (prd high-command / livekit). Rolled back to `v1.0.3`. Fix affinity (run DS on all nodes) before retrying
- RKE2 leaf certs expire 2027-10-05 (poc-apps-1 2027-09-19); renew again from 2027-06-07 per [docs/RKE2_CERT_ROTATION.md](docs/RKE2_CERT_ROTATION.md)
- Do **not** revoke the TrueNAS API key that was in `democratic_csi_api_key`: it is the key TrueNAS CSI uses ([docs/TRUENAS_CSI_MIGRATION.md](docs/TRUENAS_CSI_MIGRATION.md#truenas-manual))
- Orphaned graylog `opensearch-bootstrap-password-webhook` on nprd-apps; delete them — see [docs/OPS_NOTES.md](docs/OPS_NOTES.md#known-issues-2026-10-05)
- GitLab mirror (`dk-raas/dkai/devops/rancher-deploy`) last synced 2026-04-26 — investigate mirror push workflow

## [Previous unreleased notes — kept until next tagged release]

### Added
- `scripts/setup-rancher-kubeconfig.sh` (`make rancher-kubeconfig`): kubeconfigs that authenticate via the Rancher CLI (`rancher token` exec plugin) instead of embedded tokens; `--auth-provider` for SSO and `--break-glass` for `<cluster>-local` contexts
- [docs/CLUSTER_ACCESS_AND_SSO.md](docs/CLUSTER_ACCESS_AND_SSO.md): Authentik → Rancher SAML → kubectl, first-time setup, SAML/Authentik reference, token settings, break-glass layers, automation guidance, certificate calendar, troubleshooting
- `RANCHER_KUBECONFIG_ARGS` for `make rancher-kubeconfig`
- [docs/RKE2_CERT_ROTATION.md](docs/RKE2_CERT_ROTATION.md): per-node RKE2 cert expiry table and rolling leaf-cert rotation runbook (plan; expiry 2027-01-08 / 2027-01-15)
- Break-glass RKE2 admin kubeconfigs `~/.kube/<cluster>-rke2.yaml` (direct `<cluster>.dataknife.net:6443`, kept out of `~/.kube/config`) with fetch procedure in CLUSTER_ACCESS_AND_SSO.md

### Changed (2026-10 wave)
- Rancher login via Authentik SAML (Rancher "Keycloak (SAML)" provider, site access `required`, allow-listed principals only) alongside local auth; `kubeconfig-generate-token=false`, `kubeconfig-default-token-ttl-minutes=129600` (live settings, not managed by Terraform)
- Docs: Rancher API token path is `config/.rancher-api-token` and expires after 90 days (`auth-token-max-ttl-minutes`), not "never"; current-state notes in downstream registration, deployment, troubleshooting, ops notes; RKE2/Rancher version examples updated to `v1.36.2+rke2r1` / `v2.15.0`; README license corrected to Apache-2.0
- [docs/UPGRADE_PLAN.md](docs/UPGRADE_PLAN.md): prioritized next upgrade wave (reviewed 2026-10-04) and the cert-manager v1.21.2 rollout log
- **cert-manager** pin `v1.19.2` → **`v1.21.2`**. Live clusters were already on `v1.21.1` via manual Helm (2026-07-31); Terraform now owns the version again
- cert-manager module: Helm values `crds.enabled=true,crds.keep=true` and `config.gatewayAPI.enabled=true` for the gateway-shim
- **Rancher** pin `v2.15.0` → **`v2.15.2`** (live since 2026-10-04)
- **Envoy Gateway** `v1.6.1` → **`v1.9.2`** and **Gateway API** CRDs `v1.4.1` → **`v1.6.1`** ([#40](https://github.com/DataKnifeAI/rancher-deploy/pull/40), [#42](https://github.com/DataKnifeAI/rancher-deploy/pull/42))
- **CloudNativePG** default `1.28.0` → **`1.30.1`** ([#41](https://github.com/DataKnifeAI/rancher-deploy/pull/41))
- Execution logs for 2026-10-04 / 2026-10-05 waves in [docs/UPGRADE_PLAN.md](docs/UPGRADE_PLAN.md)

### Fixed (2026-10 wave)
- CloudNativePG resources no longer have destroy provisioners ([#41](https://github.com/DataKnifeAI/rancher-deploy/pull/41))
- Envoy Gateway module no longer deletes Gateway API CRDs on a version mismatch ([#40](https://github.com/DataKnifeAI/rancher-deploy/pull/40))
- cert-manager module no longer deletes CRDs/namespace when it cannot see the Helm release unless `cleanup_unmanaged_install = true`
- Broken doc links and break-glass kubeconfig docs; poc-apps wildcard cert sync ([gitops-core#6](https://github.com/DataKnifeAI/gitops-core/pull/6))

### Removed (2026-10 wave)
- **democratic-csi** variables/resources/scripts/docs; TrueNAS CSI is the only storage driver
- **GitHub ARC, MongoDB Community operator, OpenSearch operator** resources and helper scripts ([#46](https://github.com/DataKnifeAI/rancher-deploy/pull/46))

## [1.2.0-beta.1] - 2026-08-31

First GitHub prerelease of the fleet stack. Palworld operator on prd is treated as **beta** (usable for hosting, not production-hardened). Operator source and image versioning live in [DataKnifeAI/palworld-operator](https://github.com/DataKnifeAI/palworld-operator) (`v0.1.0-beta.1`).

### Added
- Optional **Palworld operator** install (default **prd-apps** only) from a digest-pinned Harbor image
- Optional **large worker** pool on app clusters (`large_worker_count`, default 0)
  - RKE2 label `node-type=large` for scheduling (game servers without hostname pins)
  - Optional `large_worker_proxmox_node` per cluster (defaults to `var.proxmox_node`)
- **poc-apps** cluster; **kube-vip** LoadBalancer path (MetalLB retired)
- **TrueNAS CSI** (alongside Democratic CSI), topology labels, Harbor CRI / registries bootstrap
- Gated day-2 OS patch and RKE2 upgrade flags; Rancher/RKE2 version pins
- Dedicated **cert-manager** Terraform module for nprd/prd/poc (cleanup of unmanaged installs)

### Changed
- **cert-manager** Terraform default / example pin: `v1.13.0` (EOL) → **`v1.19.2`**
  - One var feeds manager + all apps modules
  - Live manager may still be `v1.16.5`; bump via tfvars/Helm when you intend CM-M1 (see [docs/UPGRADE_PLAN.md](docs/UPGRADE_PLAN.md))
  - `v1.21.1` remains the RKE2 1.36 gate, not this default

### Fixed
- kube-vip ClusterRole verbs for Service patch/update
- TrueNAS CSI controller/node mode flags
- Orphan MetalLB CRD cleanup helper

### Known limitations
- Palworld operator does not manage `PalworldServer` CRs by itself (apply CRs separately)
- Existing large workers need a one-time `kubectl label` until re-bootstrap
- Branding/org-avatar docs are not part of this cut

## [1.1.0] - 2026-01-01

### Added
- **Automatic Logging Infrastructure**: New `apply.sh` script with automatic `TF_LOG=debug` logging
- **Timestamped Log Files**: Deploy logs saved to `terraform/terraform-<timestamp>.log`
- **Documentation Consolidation**: Streamlined from 6 docs to 4 focused guides
  - DEPLOYMENT_GUIDE.md - Complete deployment walkthrough with logging
  - TROUBLESHOOTING.md - Issue resolution and diagnostics
  - MODULES_AND_AUTOMATION.md - Terraform modules and RKE2/Rancher automation
  - CLOUD_IMAGE_SETUP.md - Ubuntu 24.04 provisioning details
- **RKE2 Troubleshooting Guide**: Complete section on version management and common issues
- **Root-level Documentation**: CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md

### Changed
- **RKE2 Version Management**: Updated from non-existent "latest" to specific versions (v1.34.3+rke2r1)
- **RKE2 Installation Script**: Improved from piped curl to download+chmod+execute pattern
- **Environment Variable Handling**: Fixed `sudo -E bash -c` pattern for proper expansion
- **Cloud-Init Provisioning**: Added `wait_for_cloud_init` to ensure networking ready before RKE2
- **Provider References**: Removed deprecated custom providers (dataknife/pve, telmate/proxmox)
- **README.md**: Updated with RKE2 version emphasis, logging instructions, consolidated doc references

### Fixed
- **RKE2 404 Errors**: Resolved "latest" version download failures by using specific release tags
- **Terraform State Caching**: Cleaned state files and validated fresh deployments
- **SSH Host Key Issues**: Added `cleanup_known_hosts` provisioner for cleaner deployments
- **RKE2 Script Execution**: Fixed edge cases with piped curl installation method
- **Documentation Overlaps**: Removed duplicate content across 6 documentation files (537 lines cleaned)

### Deprecated
- Custom Proxmox providers (now using bpg/proxmox v0.90.0 exclusively)
- "latest" RKE2 version references (must use specific versions)

## [1.0.0] - 2025-12-20

### Added
- Initial release of Rancher Deploy project
- Terraform configuration for Proxmox VE
- RKE2 Kubernetes cluster deployment
- Rancher management cluster setup
- Non-production apps cluster configuration
- Cloud-init integration for Ubuntu 24.04 LTS
- Module-based Terraform structure
  - proxmox_vm module for VM creation
  - rke2_cluster module for Kubernetes setup
  - rancher_cluster module for Rancher deployment
- Comprehensive documentation suite
  - DEPLOYMENT_GUIDE.md
  - TERRAFORM_VARIABLES.md
  - TROUBLESHOOTING.md
  - CLOUD_IMAGE_SETUP.md
- Example configurations and templates
- GitIgnore patterns for sensitive data

### Features
- ✅ Full automation from VMs to Rancher
- ✅ Cloud image provisioning (Ubuntu 24.04 LTS)
- ✅ bpg/proxmox v0.90.0 provider with reliable task polling
- ✅ RKE2 Kubernetes v1.34.3+rke2r1
- ✅ High availability 3-node clusters
- ✅ Cloud-init networking, DNS, hostnames
- ✅ Secure API token authentication
- ✅ Comprehensive troubleshooting guides

---

For detailed changes, see the [Git commit history](https://github.com/DataKnifeAI/rancher-deploy/commits/main).
