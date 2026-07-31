# Documentation index

Guides for deploying and operating Rancher / RKE2 on Proxmox with this repo.

## Start here

1. [../README.md](../README.md) — landing page, quickstart
2. [ARCHITECTURE.md](ARCHITECTURE.md) — clusters, flow, add-ons
3. [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — full deploy walkthrough
4. [API_TOKEN_AND_PERMISSIONS.md](API_TOKEN_AND_PERMISSIONS.md) — Proxmox API token
5. [DNS_CONFIGURATION.md](DNS_CONFIGURATION.md) — required DNS records
6. [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md) — `.keys/`, SSH recovery via kubectl

## Core

| Doc | Topic |
|-----|--------|
| [MODULES_AND_AUTOMATION.md](MODULES_AND_AUTOMATION.md) | Terraform modules and automation |
| [CLOUD_IMAGE_SETUP.md](CLOUD_IMAGE_SETUP.md) | Ubuntu cloud image / VM provisioning |
| [PROXMOX_AGENT_SETUP.md](PROXMOX_AGENT_SETUP.md) | qemu-guest-agent |
| [RANCHER_DOWNSTREAM_MANAGEMENT.md](RANCHER_DOWNSTREAM_MANAGEMENT.md) | Downstream registration |
| [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md) | Rancher API tokens |
| [OPS_NOTES.md](OPS_NOTES.md) | Short operational truths |

## Storage

| Doc | Topic |
|-----|--------|
| [DEMOCRATIC_CSI_TRUENAS_SETUP.md](DEMOCRATIC_CSI_TRUENAS_SETUP.md) | Democratic CSI + TrueNAS |
| [STORAGE_CLASS_DEFAULT.md](STORAGE_CLASS_DEFAULT.md) | Default storage class |
| [TRUENAS_CSI_MIGRATION.md](TRUENAS_CSI_MIGRATION.md) | Democratic → official TrueNAS CSI |
| [TRUENAS_CSI_MIGRATION_PRIORITY.md](TRUENAS_CSI_MIGRATION_PRIORITY.md) | Migration ordering |
| [TRUENAS_CSI_MULTI_NODE.md](TRUENAS_CSI_MULTI_NODE.md) | Multi-node / patched image notes |

## Platform add-ons

| Doc | Topic |
|-----|--------|
| [GATEWAY_API_SETUP.md](GATEWAY_API_SETUP.md) | Envoy Gateway / Gateway API |
| [METALLB_SETUP.md](METALLB_SETUP.md) | MetalLB (**legacy** — prefer kube-vip) |
| [CLOUDNATIVEPG_SETUP.md](CLOUDNATIVEPG_SETUP.md) | CloudNativePG |
| [GITHUB_ARC_SETUP.md](GITHUB_ARC_SETUP.md) | GitHub Actions Runner Controller |
| [CONTROL_PLANE_SCHEDULABILITY.md](CONTROL_PLANE_SCHEDULABILITY.md) | Control-plane taints / scheduling |

## Troubleshooting

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md) for lost SSH keys

## Assets

- [assets/rancher-deploy-hero.png](assets/rancher-deploy-hero.png) — README hero graphic

## Contributing docs

1. Add files under `docs/`
2. Link them from this index
3. Link from the root README only if they are core entry points
4. Prefer accurate variable names from `terraform/variables.tf` / `terraform.tfvars.example`
