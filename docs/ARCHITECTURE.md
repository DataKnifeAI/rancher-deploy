# Architecture

How this repo wires Proxmox VMs into Rancher-managed RKE2 clusters.

## High-level flow

```
Proxmox VE (cloud image → VMs)
        ↓  Terraform (bpg/proxmox)
Ubuntu 24.04 VMs + cloud-init + SSH
        ↓  RKE2 install (remote-exec / cloud-init)
RKE2 clusters (manager + nprd / prd / poc apps)
        ↓  Helm / manifests
Rancher (manager) → registers downstream clusters
        ↓  optional
CSI (TrueNAS), Envoy Gateway, kube-vip, operators
```

## Clusters

| Name | Purpose | Nodes | Default VM ID range |
|------|---------|-------|---------------------|
| `manager` / rancher-manager | Rancher + RKE2 control plane | 3 servers (no dedicated workers) | 40x (`401–403`) |
| `nprd-apps` | Non-production workloads | 3 servers + 3 workers | 41x (`410–415`) |
| `prd-apps` | Production workloads | 3 servers + 3 workers | 42x (`420–425`) |
| `poc-apps` | Proof-of-concept / sandbox | 3 servers + 3 workers | 43x (`430–435`) |

IPs, VLANs, storage, and sizing come from the `clusters` map in `terraform.tfvars`. Example defaults use `192.168.1.0/24` with manager at `.100`, nprd `.110`, prd `.120`, poc `.130` (workers continue after servers).

## Provisioning order (simplified)

1. Download Ubuntu noble cloud image to configured Proxmox nodes (`images-import`).
2. Create **manager-1**, install RKE2 primary, fetch join token over SSH → `config/.manager-token`.
3. Join manager-2/3; verify cluster; optionally install cert-manager + Rancher.
4. Create each apps cluster the same way (primary → token → additional servers → workers).
5. Register downstream clusters with Rancher (when `register_downstream_cluster = true`).
6. Install platform add-ons on apps clusters when flags are set (CSI, Envoy Gateway, kube-vip, CNPG, MongoDB, OpenSearch, GitHub ARC, Palworld operator).

RKE2 version is set in `terraform/main.tf` (currently `v1.34.3+rke2r1`). Rancher chart version comes from `rancher_version` in tfvars (example: `v2.13.1`).

## Storage

- **VM disks**: Proxmox datastore from `clusters.*.storage` (example: `local-vm-zfs`).
- **Persistent volumes** (apps clusters):
  - **Democratic CSI** → storage class `truenas-nfs` (vars: `democratic_csi_*`)
  - **Official TrueNAS CSI** → `truenas-csi-nfs` (vars: `truenas_csi_*`; SCALE 25.10+)
  - Migration between drivers: [TRUENAS_CSI_MIGRATION.md](TRUENAS_CSI_MIGRATION.md)

## Networking / ingress

- Node DNS via cloud-init (`dns_servers`); CoreDNS inherits node resolvers.
- App clusters: **kube-vip** provides `LoadBalancer` IPs from `kube_vip_ip_pools` (MetalLB is legacy; see [METALLB_SETUP.md](METALLB_SETUP.md) note).
- **Envoy Gateway** when `install_envoy_gateway = true`.

## Optional operators

Enabled via Terraform flags / versions in tfvars:

| Component | Notes |
|-----------|--------|
| CloudNativePG | PostgreSQL operator on apps clusters |
| MongoDB Community Operator | For charts that need MongoDB CRs |
| OpenSearch Operator | Search / logging stacks |
| GitHub ARC | Actions runners (see [GITHUB_ARC_SETUP.md](GITHUB_ARC_SETUP.md)) |
| Palworld operator | Manifests from Harbor; **default on prd-apps only** (`install_palworld_operator_prd`) |

## Terraform layout

- Root module: `terraform/main.tf` (primary path for full stack)
- Modules: `proxmox_vm`, `rke2_*`, `rancher_cluster`, `rancher_downstream_registration`, `cert_manager`, `envoy_gateway`, `kube-vip`, …
- Optional split environments under `terraform/environments/` (manager / nprd-apps) — secondary to the root module

## SSH & local state artifacts

- Deploy key path: `ssh_private_key` (public key = `${path}.pub`). Repo convention: `.keys/` (gitignored).
- Tokens / kubeconfigs: under `config/` and `~/.kube/*.yaml` (gitignored).
- See [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md).
