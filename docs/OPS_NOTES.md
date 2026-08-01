# Ops notes

Short operational truths that do not belong in the README.

## SSH deploy keys

- Live keys live under **`.keys/`** (gitignored). See [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md).
- If SSH is broken but kubectl works, recover by injecting `authorized_keys` via `kubectl debug` — do not mass-replace healthy VMs for key rotation alone.

## Storage

- **Democratic CSI** (`democratic_csi_*`, class `truenas-nfs`) is the common default path.
- **Official TrueNAS CSI** (`truenas_csi_*`, class `truenas-csi-nfs`) is optional and can coexist during migration; old Democratic volumes are not mountable by the new driver. See [TRUENAS_CSI_MIGRATION.md](TRUENAS_CSI_MIGRATION.md) and [TRUENAS_CSI_MULTI_NODE.md](TRUENAS_CSI_MULTI_NODE.md).
- Apps-cluster nodes get label `topology.truenas.io/pool=<truenas_csi_pool>` via RKE2 `node-label` at bootstrap, plus a post-kubeconfig `null_resource` that labels all nodes. Manager nodes are not labeled (CSI is apps-side).

## Harbor / registries (node containerd)

- Harbor uses **Let's Encrypt** — no custom CA on nodes (`harbor-ca.crt` is legacy; do not install).
- Optional mirrors only: `config/rke2-registries.yaml` → `/etc/rancher/rke2/registries.yaml` via `rke2_registries_yaml_file` (default under `config/`). Missing file skips silently.
- Example: `terraform/templates/rke2-registries.yaml.example` (no `tls.ca_file`).
- Bootstrap lives in `proxmox_vm` `null_resource.rke2_bootstrap` (split from the VM resource so a bpg/proxmox post-create failure does not skip RKE2 install).
- **Manual repair** (e.g. replaced worker before TF managed registries): copy `registries.yaml` from a sibling if used, `sudo systemctl restart rke2-agent` (or `rke2-server`), then `kubectl label node <name> topology.truenas.io/pool=<pool> --overwrite`.
- **bpg/proxmox base64 fallback:** if apply fails with `illegal base64 data` after the VM already exists, SSH pubkey is now `trimspace`d; re-run apply so `null_resource.rke2_bootstrap` can finish, or run `cloud-init-rke2.sh` over SSH with the same env vars. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## LoadBalancer

- Current Terraform path installs **kube-vip** (`install_kube_vip`, `kube_vip_ip_pools`).
- **MetalLB** docs and `scripts/remove-metallb.sh` remain for cleanup of older installs. Prefer kube-vip for new work.

## Palworld operator

- Terraform flag `install_palworld_operator_prd` defaults to **true**; nprd/poc default **false**.
- Installs into `palworld-operator-system` from a Harbor image (digest-pinned in tfvars example). Does not manage game `PalworldServer` CRs by itself.

## Proxmox host networking (cluster ops)

This repo creates guest VMs; it does **not** manage Proxmox host bonds/bridges. For live migrations and storage traffic, keep host-side migration/storage networks correct in Proxmox (dedicated bridge/VLAN, `migration:` settings in datacenter config if used). Fix host networking in Proxmox — not in this Terraform root — when migrations are slow or pinned to the wrong NIC.

Example layout (mgmt `vmbr0`/`bond0`, storage jumbo `vmbr1`/`bond1`, aux `vmbr2`/`bond2`, local ZFS vs Ceph RBD vs TrueNAS CSI): [../examples/homelab/index.html](../examples/homelab/index.html).

## Secrets hygiene

| Path | Purpose |
|------|---------|
| `terraform/terraform.tfvars` | API tokens, passwords (gitignored) |
| `.keys/` | SSH deploy keys (gitignored) |
| `config/` | Tokens, registry pull secrets (gitignored) |
| `helm-values/democratic-csi-truenas.yaml` | Generated CSI values (gitignored) |
