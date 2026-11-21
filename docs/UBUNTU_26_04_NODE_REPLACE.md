# Ubuntu 26.04 node-by-node replacement

**Status:** plan only (do not apply until a dedicated window).  
**Live OS:** Ubuntu 24.04.5 LTS (`ubuntu-noble-cloudimg-amd64.qcow2`).  
**Target:** Ubuntu 26.04 LTS Resolute (`ubuntu-resolute-cloudimg-amd64.qcow2`).  
**RKE2:** v1.36.x matrix lists Ubuntu 26.04 (validated ≥ v1.36.4). Prefer staying on **v1.36.6** for the OS wave; do **not** stack Rancher 2.16 / RKE2 1.37 in the same window.

## Why replace (not in-place upgrade)

- Terraform / Proxmox path is cloud-image clone + cloud-init + `null_resource.rke2_bootstrap`.
- In-place `do-release-upgrade` across 31 RKE2 nodes is longer, harder to roll back, and fights image drift vs new joins.
- Canonical’s automatic 24.04→26.04 path is oriented around **26.04.1**; treat cluster cutover as rebuild either way.

## Preconditions

1. Etcd snapshots + Rancher Backup for the cluster under change.
2. Confirm free Proxmox capacity for one extra VM during swap (or reuse after delete).
3. Pin `ubuntu_cloud_image_url` to Resolute **only when starting**; do not untargeted-apply the whole root.
4. Keep `enable_os_patch` / `enable_rke2_upgrade` false; use scripts + targeted module applies.
5. Break-glass kubeconfigs `~/.kube/<cluster>-apps-rke2.yaml` (manager: `rancher-manager-rke2.yaml`).
6. Games / VIPs / Harbor RWO: drain carefully; one worker at a time for apps, one CP at a time for etcd.

## Order

1. **poc-apps** workers → control-plane (canary).
2. **nprd-apps** workers → control-plane.
3. **prd-apps** workers (incl. large-worker) → control-plane.
4. **rancher-manager** last (one CP at a time; Rancher HA).

Per node: cordon → drain → replace VM (or join new then delete old) → wait Ready → uncordon next.

## Per-node procedure (worker)

1. `kubectl cordon <node>`
2. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m`
3. Proxmox: stop/delete old VM **or** leave powered off until new node is healthy.
4. Terraform: targeted apply for that `module.*_workers["…"]` only (new cloud image already downloaded on the node datastore), with `-refresh=false` if manager/smbios noise appears.
5. Bootstrap remote-exec installs RKE2 agent at pinned `rke2_version` (idempotent if re-run).
6. Label TrueNAS topology if missing: `topology.truenas.io/pool=SAS`.
7. `kubectl wait --for=condition=Ready node/<new> --timeout=10m`
8. Smoke: CSI mount, a sample Ingress/HTTPRoute host, kube-vip if the node held a VIP.

## Per-node procedure (control-plane)

Same as worker, plus:

1. Confirm etcd member healthy before drain (`kubectl get nodes`, RKE2 etcd checks).
2. Never drain the last Ready CP.
3. After join: verify `kubectl get --raw=/readyz` and Rancher cluster Connected.

## Image / Terraform changes (when executing)

- `var.ubuntu_cloud_image_url` → Resolute cloudimg URL.
- `proxmox_virtual_environment_download_file.ubuntu_cloud_image` `file_name` → `ubuntu-resolute-cloudimg-amd64.qcow2`.
- Download with `overwrite=false`; plan per-node module targets only.
- Update `docs/OPS_NOTES.md` OS pin after the wave.

## Abort / rollback

- Leave old VM disks until the replacement has soaked ≥24h on poc.
- Re-attach / power on previous VM and re-join only if the new node fails bootstrap (prefer restore from snapshot over mixed-OS long-term).

## Out of scope this plan

- Rancher 2.16 / RKE2 1.37.
- Stoat operator Ingress→HTTPRoute (operator still owns Ingress).
- Untargeted apply of remaining null_resource operator/CNPG drift.
