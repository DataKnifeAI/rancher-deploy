# Ubuntu 26.04 node-by-node replacement

**Status:** complete for app clusters + **rancher-manager** (2026-11-22).  
**Live OS:** **Ubuntu 26.04.1 LTS** everywhere (`ubuntu-resolute-cloudimg-amd64.qcow2`; was 24.04.5).  
**RKE2:** pin **v1.36.6+rke2r1**; do **not** stack Rancher 2.16 / RKE2 1.37 on this wave.

## Why replace (not in-place upgrade)

- Terraform / Proxmox path is cloud-image clone + cloud-init + `null_resource.rke2_bootstrap`.
- Disk `ignore_changes` means image bumps alone do not recreate VMs — use `-replace` on the VM **and** bootstrap.
- Canonical’s automatic 24.04→26.04 path is oriented around **26.04.1**; treat cluster cutover as rebuild either way.

## Preconditions

1. Etcd snapshots + Rancher Backup for the cluster under change.
2. Resolute image downloaded on every Proxmox node datastore (`proxmox_virtual_environment_download_file.ubuntu_cloud_image`).
3. Pin `ubuntu_cloud_image_url` to Resolute; do **not** untargeted-apply the whole root.
4. Keep `enable_os_patch` / `enable_rke2_upgrade` false.
5. Break-glass kubeconfigs `~/.kube/<cluster>-apps-rke2.yaml` (manager: `rancher-manager-rke2.yaml`).
6. TF state backup under `~/terraform-state-backups/rancher-deploy/`.

## Order

1. **poc-apps** workers → control-plane — **done 2026-11-22** (all 9 nodes Ubuntu 26.04.1 / RKE2 v1.36.6).
2. **nprd-apps** workers → control-plane — **done 2026-11-22** (all 9 nodes Ubuntu 26.04.1 / RKE2 v1.36.6).
3. **prd-apps** workers (incl. large-worker) → control-plane — **done 2026-11-22** (10 nodes Ubuntu 26.04.1 / RKE2 v1.36.6). CP order: `prd-apps-3` → `prd-apps-2` → `prd-apps-1` (primary VM-only replace + join to `.121`; Proxmox reset + manual `sudo env` bootstrap if QEMU/TF base64 flake).
4. **rancher-manager** last (one CP at a time; Rancher HA) — **done 2026-11-22** (all 3 CPs Ubuntu 26.04.1 / RKE2 v1.36.6). Recovery path: if a node is already gone from the API, use **TF-only replace** (skip `ubuntu2604-replace-node.sh` `need_kube`). Terraform `for_each` keys are **`manager-2` / `manager-3`** (not `rancher-manager-*`).

## Per-node procedure (worker)

1. `kubectl cordon <node>` then `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m`
2. Clear RKE2 rejoin blockers **before** the new agent comes up:
   - `kubectl delete node <node> --wait=false`
   - `kubectl -n kube-system delete secret <node>.node-password.rke2 --ignore-not-found`
3. Terraform (from `terraform/`, `-refresh=false`):

```bash
terraform apply -refresh=false -auto-approve \
  -replace='module.<workers>["<name>"].proxmox_virtual_environment_vm.vm' \
  -replace='module.<workers>["<name>"].null_resource.rke2_bootstrap[0]' \
  -target='module.<workers>["<name>"].proxmox_virtual_environment_vm.vm' \
  -target='module.<workers>["<name>"].null_resource.rke2_bootstrap[0]' \
  -target='data.local_file.<cluster>_token[0]'
```

4. If the VM is up in Proxmox but has no ping after ~8–10 minutes (qemu-agent wait), `POST .../status/reset` once — first boot on Resolute sometimes stalls until reset.
5. SSH with `-o UserKnownHostsFile=/dev/null` (host key changes every replace).
6. Wait Ready (new node object); confirm `OS-IMAGE` is `Ubuntu 26.04.1 LTS`.
7. Ensure `topology.truenas.io/pool=SAS`; uncordon.

## Per-node procedure (control-plane)

Same as worker, plus:

1. Etcd snapshot on a healthy server before the first CP replace.
2. Never drain the last Ready CP.
3. After join: `kubectl get --raw=/readyz` and Rancher cluster Connected.

## Lessons from canary (`poc-apps-worker-6`)

| Issue | Fix |
| --- | --- |
| Ubuntu 26.04 `sudo` ignores `-E` (“preserving the entire environment is not supported”) → empty `SERVER_IP` / `RKE2_VERSION` | Bootstrap provisioner uses `sudo env …` (`modules/proxmox_vm/main.tf`) |
| Same hostname → `Node password rejected` | Delete node + `*.node-password.rke2` secret before/while rejoining |
| QEMU guest agent timeout (~15m) on first create | Proxmox reset after ~5m without ping; agent then publishes NICs |
| Replacing TF “primary” with empty `SERVER_IP` | Would **init a new cluster**. Drain/delete node, `-replace` **VM only**, then bootstrap as **secondary** joining another live CP (`SERVER_IP=<sibling>`). Graft `null_resource` triggers to match module (empty `rke2_server_ip`) so TF does not re-run init |
| Resolute cloud-image root ~2.4G until `growpart` | Proxmox disk is **`virtio0`** (not `scsi0`). Resize to 80G in PVE, reboot, `growpart` + `resize2fs` before RKE2 install |
| Long Cursor shell chains + overlapping agents | Run **one node per `nohup`** with logs in `/tmp/mgr-replace-*.log`; poll `kubectl` between steps. TF `for_each` keys are `manager-2`/`manager-3`, not `rancher-manager-2` |

## Image / Terraform pins

- `ubuntu_cloud_image_url` → `https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img`
- `file_name` → `ubuntu-resolute-cloudimg-amd64.qcow2`
- `docs/OPS_NOTES.md` Version pins section updated 2026-11-22 (live OS + RKE2 pin).
- Bootstrap provisioner already uses `sudo env …` (not `sudo -E`) in `terraform/modules/proxmox_vm/main.tf` for Ubuntu 26.04+.

## Abort / rollback

- Old disks may remain (`delete_unreferenced_disks_on_destroy = false`) until soak ≥24h on poc.
- Prefer etcd/VM restore over long-term mixed-OS if a join fails badly.

## Out of scope this wave

- Rancher 2.16 / RKE2 1.37.
- Untargeted apply of remaining null_resource operator/CNPG drift.
