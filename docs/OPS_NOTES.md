# Ops notes

Short operational truths that do not belong in the README.

## Cluster access (SSO)

- Rancher `v2.15.2` at `https://rancher.dataknife.net`; auth providers **local** + **Keycloak (SAML)** pointed at Authentik (`https://auth.dataknife.net`, on prd-apps). Full guide: [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md).
- kubectl: `./scripts/setup-rancher-kubeconfig.sh --install-cli --merge --auth-provider keyCloakProvider --break-glass`, then `kubectl --context <local|nprd-apps|prd-apps|poc-apps>`. Kubeconfigs embed no tokens; `rancher token` caches one (≤ 90 days) in `~/.rancher/cli2.json`.
- SAML site access is **`required`** by design: only principals in `allowedPrincipalIds` may log in via SSO (currently `keycloak_user://4` = akadmin). Allow people via an Authentik group, `keycloak_group://<exact group name>`; single users are `keycloak_user://<Authentik numeric pk>`, not the username. Local logins are unaffected. See [CLUSTER_ACCESS_AND_SSO.md § Site access](CLUSTER_ACCESS_AND_SSO.md#site-access-required).
- Break-glass: `<cluster>-local` contexts (Rancher local user), UI **Log in with Local User**, RKE2 admin kubeconfigs `~/.kube/<cluster>-rke2.yaml` (independent of Rancher/Authentik; client certs expire 2027-10-05 after the 2026-10-04 renewal — re-fetch after every RKE2 cert renewal per [RKE2_CERT_ROTATION.md](RKE2_CERT_ROTATION.md)), Authentik recovery key.
- Global settings: `kubeconfig-generate-token=false`, `kubeconfig-default-token-ttl-minutes=129600`, `auth-token-max-ttl-minutes=129600` (default) — so **every** Rancher API token, including Terraform's `ttl: 0` one, expires in 90 days.
- Unattended jobs: use a dedicated scoped API token or RKE2 admin kubeconfigs, never a personal SSO token cache.

## SSH deploy keys

- Live keys live under **`.keys/`** (gitignored). See [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md).
- If SSH is broken but kubectl works, recover by injecting `authorized_keys` via `kubectl debug` — do not mass-replace healthy VMs for key rotation alone.

## Storage

- **Official TrueNAS CSI** (`truenas_csi_*`, driver `csi.truenas.io`, class `truenas-csi-nfs`) is the only CSI driver on the app clusters. See [TRUENAS_CSI_MULTI_NODE.md](TRUENAS_CSI_MULTI_NODE.md).
- **democratic-csi removed (2026-10-04).** No driver, StorageClass, PV, Helm release or namespace left on any cluster; the last orphaned `Released` PV on nprd (`pvc-25d4289c…`, old Loki ingester) was deleted (its dataset `/mnt/SAS/RKE2/pvc-25d4289c-38a0-4c20-96ef-35d2cd91356d` is still on TrueNAS). The `democratic_csi_*` variables, resources, output and scripts are gone from this repo. Migration history: [TRUENAS_CSI_MIGRATION.md](TRUENAS_CSI_MIGRATION.md).
- **Don't revoke the TrueNAS API key that was in `democratic_csi_api_key`.** It is the same key as `truenas_csi_api_key` (TrueNAS key ID 4), live in `truenas-csi/truenas-api-credentials` on nprd, prd and poc; revoking it breaks TrueNAS CSI everywhere. Move TrueNAS CSI to a new key first if you want it gone. The older democratic-csi keys (IDs 1 and 2) are unused: revoke them.
- Apps-cluster nodes get label `topology.truenas.io/pool=<truenas_csi_pool>` via RKE2 `node-label` at bootstrap, plus a post-kubeconfig `null_resource` that labels all nodes. Manager nodes are not labeled (CSI is apps-side).

## Version pins (RKE2 / Rancher / OS)

Live clusters match these defaults (verified 2026-10-04: Rancher `v2.15.2`, all four clusters RKE2 `v1.36.2+rke2r1`, cert-manager `v1.21.2` on the app clusters and `v1.21.1` on the manager, Ubuntu kernel `6.8.0-146` on all 31 nodes).

| Pin | Variable | Default (as of 2026-10) | Notes |
|-----|----------|-------------------------|--------|
| RKE2 | `rke2_version` | `v1.36.2+rke2r1` | New nodes only unless `enable_rke2_upgrade=true`. Needs Rancher 2.15+ (2.14.x max certified RKE2 is 1.35) |
| Rancher | `rancher_version` | `v2.15.2` | Stable chart with K8s/RKE2 1.36 support; **minor upgrades must step** latest patch of current minor first (e.g. `v2.14.3` → `v2.14.4` → `v2.15.0`) |
| Unattended upgrades | `enable_unattended_upgrades` | `true` | Security pocket only; `Automatic-Reboot false`. New nodes via `cloud-init-rke2.sh`; existing via `scripts/enable-unattended-upgrades.sh` |
| OS patch | `enable_os_patch` | `false` | SSH `apt update/upgrade` via `scripts/patch-os-nodes.sh`; optional `os_patch_reboot` |

**Apply path (when ready — not automatic):**
1. Unattended-upgrades: default **on** — next apply configures existing nodes (idempotent); set `enable_unattended_upgrades=false` to skip. New VMs always get it at bootstrap. Reboots stay manual (`/var/run/reboot-required`).
2. OS: set `enable_os_patch=true`, bump `os_patch_trigger`, prefer `os_patch_reboot=false`, drain/reboot manually if needed.
3. RKE2: set `rke2_version`, then either replace nodes or set `enable_rke2_upgrade=true` (rolling SSH installer, **no drain** — cordon/drain yourself). No system-upgrade-controller Plans in this repo.
4. Rancher: change `rancher_version` and apply (targets `module.rancher_deployment`); follow supported minor stepping.

**Live upgrade runbook (poc-apps canary, stepped pins, abort criteria):** [UPGRADE_PLAN.md](UPGRADE_PLAN.md).

## Harbor / registries (node containerd)



- Harbor uses **Let's Encrypt** — no custom CA on nodes (`harbor-ca.crt` is legacy; do not install).
- Optional mirrors only: `config/rke2-registries.yaml` → `/etc/rancher/rke2/registries.yaml` via `rke2_registries_yaml_file` (default under `config/`). Missing file skips silently.
- Example: `terraform/templates/rke2-registries.yaml.example` (no `tls.ca_file`).
- Bootstrap lives in `proxmox_vm` `null_resource.rke2_bootstrap` (split from the VM resource so a bpg/proxmox post-create failure does not skip RKE2 install).
- **Manual repair** (e.g. replaced worker before TF managed registries): copy `registries.yaml` from a sibling if used, `sudo systemctl restart rke2-agent` (or `rke2-server`), then `kubectl label node <name> topology.truenas.io/pool=<pool> --overwrite`.
- **bpg/proxmox base64 fallback:** if apply fails with `illegal base64 data` after the VM already exists, SSH pubkey is now `trimspace`d; re-run apply so `null_resource.rke2_bootstrap` can finish, or run `cloud-init-rke2.sh` over SSH with the same env vars. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## LoadBalancer

- Current Terraform path installs **kube-vip** (`install_kube_vip`, `kube_vip_ip_pools`). kube-vip replaced MetalLB for LoadBalancer services.
- **MetalLB** docs and `scripts/remove-metallb.sh` remain for cleanup of older installs. Prefer kube-vip for new work.
- After MetalLB removal, orphan `*.metallb.io` CRDs (e.g. `communities`, `configurationstates`, `servicebgpstatuses`, `servicel2statuses`) may remain on nprd/prd/poc. Clear them with `./scripts/remove-metallb.sh` (uses `~/.kube/{nprd,prd,poc}-apps.yaml`).

## Palworld operator

- Terraform flag `install_palworld_operator_prd` defaults to **true**; nprd/poc default **false**.
- Installs into `palworld-operator-system` from a Harbor image (digest-pinned in tfvars example). Does not manage game `PalworldServer` CRs by itself.

## Proxmox host networking (cluster ops)

This repo creates guest VMs; it does **not** manage Proxmox host bonds/bridges. For live migrations and storage traffic, keep host-side migration/storage networks correct in Proxmox (dedicated bridge/VLAN, `migration:` settings in datacenter config if used). Fix host networking in Proxmox — not in this Terraform root — when migrations are slow or pinned to the wrong NIC.

Example layout (mgmt `vmbr0`/`bond0`, storage jumbo `vmbr1`/`bond1`, aux `vmbr2`/`bond2`, local ZFS vs Ceph RBD vs TrueNAS CSI): [../examples/homelab/index.html](../examples/homelab/index.html).

## Known issues (2026-10-04)

- **TrueNAS CSI pods restart often on all app clusters.** The TrueNAS API (middlewared, `192.168.9.10`) freezes for ~20–60 s about every 7 minutes; the driver's liveness probe treats the lost API connection as fatal. A driver fix is in progress in the `truenas-csi` fork. Restarts are noisy but mounts recover; don't chase them per pod.
- **CNPG replicas stuck on timeline divergence (prd-apps) — fixed 2026-10-04.** `coder-postgres-1` and `high-command-postgres-1` were re-cloned with `kubectl cnpg destroy <cluster> <n> -n <ns>` (now `-6` and `-4`; both clusters 3/3). coder's dead slot had pinned about 115 GB of WAL by LSN (3.8G on disk thanks to ZFS compression). pg_wal is back to about 20M. Every CNPG cluster now sets `max_slot_wal_keep_size` (1–4GB, sized to the volume). Rebuild any future broken replica the same way. Use a `kubectl-cnpg` plugin that matches the operator version (1.30.x since 2026-10-04).
- **CNPG backups (since 2026-10-04).** All four clusters (prd-apps: coder, high-command, authentik; nprd-apps: harbor) archive WAL and take daily base backups through the Barman Cloud plugin (gitops-core `cnpg-barman-cloud`) to `s3://rke2-backups/cnpg/<k8s-cluster>/<db>/`. They use the rustfs S3 API on port **30292**; 30293 is the console. Retention is 14 days. Restore and checks are documented in each repo's README. Adding the plugin rolled each cluster with an in-place primary restart (`primaryUpdateMethod: restart`): Authentik SSO was down about 4 min (its server pods were restarted by the liveness probe); Coder and high-command lost the DB for under a minute. Since 2026-10-04 all four clusters use `primaryUpdateMethod: switchover`. The CNPG 1.30.1 upgrade and the node drains cost authentik about 10–15 s per switchover and the others nothing measurable.
- **Open: CNPG backups share the `rke2-backups` bucket and key with Rancher backups.** The existing rustfs key can't create buckets. Create a dedicated `cnpg-backups` bucket and a key scoped to it in the rustfs console, then update the `cnpg-backup-rustfs` Secrets (coder, high-command, authentik on prd-apps; harbor on nprd-apps) and each ObjectStore's `destinationPath`.
- **high-command-postgres is now Fleet-managed** (gitops-mcp `k8s/high-command/`, adopted with `helm.takeOwnership`). Helm two-way-patches custom resources, so adoption only adds ownership metadata. Spec and Fleet labels were synced to git by hand once. Keep the manifest identical to live, including CNPG-defaulted fields such as `plugins[].enabled`, or Fleet's drift correction loops rollbacks.
- **poc-apps wildcard cert expired (2026-04-18) — RESOLVED 2026-10-04** via [gitops-core#6](https://github.com/DataKnifeAI/gitops-core/pull/6). `cert-manager/cert-sync` had been failing for poc-apps (Rancher proxy URL with a deleted token, x509 failure) while reporting success. All four entries of `cert-sync-kubeconfig` are now RKE2 admin client certs against `:6443`, and the job exits non-zero on any failure. The Secret was rebuilt after each cluster's RKE2 cert renewal on 2026-10-04, and each manual `cert-sync` run synced all four clusters. Its client certs now expire 2027-10-05. See [CLUSTER_ACCESS_AND_SSO.md § Certificate calendar](CLUSTER_ACCESS_AND_SSO.md#certificate-and-expiry-calendar).
- **RKE2 leaf certs renewed 2026-10-04** by the rolling OS reboots (restart-triggered renewal inside the 120-day window). All server leaf certs and all agent certs now expire **2027-10-05**; poc-apps-1's server certs stay at 2027-09-19. Next renewal: any rke2 restart from 2027-05-22 (poc-apps-1) / 2027-06-07 (everything else), or `rke2 certificate rotate`. Details in [RKE2_CERT_ROTATION.md](RKE2_CERT_ROTATION.md#renewal-on-2026-10-04).
- **LAN `:443` on Gateway VIPs answers with ingress-nginx (prd-apps).** `192.168.14.184:443` (high-command Gateway) and `.187:443` return the ingress-nginx default `*.dataknife.net` cert, not Envoy's `hc.dataknife.ai` cert. The rke2-ingress-nginx DaemonSet uses `hostPort: 443`, and the CNI hostPort DNAT matches **any** local address, including kube-vip VIPs bound on that node (`.184`/`.187` live on prd-apps-2). The high-command Envoy Service is also `externalTrafficPolicy: Local` with its only proxy pod on another node, so traffic would be dropped even without nginx. Public `hc.dataknife.ai` is unaffected: it goes through the Cloudflare tunnel. Fix options: an `EnvoyProxy` with `externalTrafficPolicy: Cluster` for high-command, plus either HTTPS listeners on a non-443 port or ingress-nginx off hostPort (the Traefik migration, [UPGRADE_PLAN.md](UPGRADE_PLAN.md) #8).
- **Gateway API v1.6 follow-ups.** TCPRoute/UDPRoute storage moved to `v1`, but the game-server manifests in gitops still use `v1alpha2`, which is served but deprecated. Migrate the manifests to `v1`, rewrite stored objects (storage-version migration), then trim `status.storedVersions` on the CRDs. The orphaned `xlistenersets.gateway.networking.x-k8s.io` CRD (replaced by `listenersets` in v1.5) can be deleted once nothing lists it.
- **Pre-existing on prd, not caused by the upgrades:** satisfactory routes show `ResolvedRefs=False` (no satisfactory server pod), and the windrose dashboard returns HTTP 000.
- **Disk on prd-apps-worker-1 and -6 is 82–84%** after the 2026-10-04 reboots (worker-3 73%), close to the kubelet's default 85% image-GC threshold. Prune images or grow the disks.
- **Game servers are pinned to single nodes:** palworld by a hostname nodeSelector (`prd-apps-worker-6`), windrose by `node-type: large` (only `prd-apps-large-worker-1`). Draining those nodes means downtime until the node is back (about 4–5 min for a reboot).
- **Grafana chart is frozen.** `grafana/grafana` stops at `10.5.15`; nprd runs `12.4.12` through an `image.tag` override. Move to `grafana-community/grafana` before Grafana 13.
- **system-upgrade-controller** is `v0.20.1` on every cluster after the Rancher `v2.15.2` upgrade (the release notes list `v0.20.2`). Check whether Rancher rolls it, or update the managed app.
- **Terraform's Rancher API token is expired** (`config/.rancher-api-token` = `rancher_api_token` in tfvars, HTTP 401), and the registration modules read a hard-coded `/home/lee/git/rancher-deploy/config/.rancher-api-token`. Refresh before any `register_downstream_cluster` apply — [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md).
- **Break-glass kubeconfigs — resolved 2026-10-04.** Break-glass now lives in `~/.kube/<cluster>-rke2.yaml` (RKE2 admin, straight to `https://<cluster>.dataknife.net:6443`; `manager.dataknife.net` for rancher-manager). The old `~/.kube/<cluster>.yaml` files on the main workstation are Rancher-proxied token kubeconfigs (`rancher-manager.yaml`'s token is expired); don't use them for break-glass. Terraform's `get_kubeconfig` will overwrite them with RKE2 admin kubeconfigs on the next full apply. See [CLUSTER_ACCESS_AND_SSO.md § Fallback](CLUSTER_ACCESS_AND_SSO.md#fallback-and-break-glass).

## Secrets hygiene

| Path | Purpose |
|------|---------|
| `terraform/terraform.tfvars` | API tokens, passwords (gitignored) |
| `.keys/` | SSH deploy keys (gitignored) |
| `config/` | Tokens (incl. `.rancher-api-token`), registry pull secrets (gitignored) |
| `~/.config/rancher-saml/` | Rancher SAML SP cert/key + Authentik IdP metadata (outside the repo) |
| `~/.rancher/cli2.json` | Rancher CLI token cache (`rancher token delete all` to clear) |
| `~/.kube/*.yaml`, `~/.kube/config*` | Kubeconfigs; RKE2 admin ones are cluster-admin |
| `state/terraform.tfstate*` | Local Terraform state (backend path `../state/`); holds secrets in plaintext (gitignored) |

On the main workstation `state/terraform.tfstate*` were mode `0777` on 2026-10-04 (and `terraform/terraform.tfstate.*.backup` `0644`). Fix with `chmod 600 state/terraform.tfstate* terraform/terraform.tfstate.*.backup`; keep `terraform.tfvars` at `0600`.
