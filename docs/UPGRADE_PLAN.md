# Upgrade runbook (poc-apps canary)

Concrete day-2 upgrade path from **live** pins to **PR #15** targets. Review this before any apply. **Do not** run `terraform apply` or live upgrades from this doc alone — treat every phase as a gated checklist.

| | Live (start) | Target (PR #15) | Live after promote (2026-08-01) |
|--|--------------|-----------------|--------------------------------|
| Rancher | `v2.13.1` | `v2.15.0` | `v2.15.0` |
| RKE2 | `v1.34.3+rke2r1` | `v1.36.2+rke2r1` | all clusters `v1.36.2+rke2r1` |
| Manager cert-manager | `v1.16.5` | `v1.21.1` (aim `v1.21.x`) | `v1.21.1` |
| Apps cert-manager | `v1.19.2` | `v1.21.1` (aim `v1.21.x`) | `v1.21.1` |

**Safe order:** backups → manager cert-manager → stepped Rancher → apps cert-manager → RKE2 stepped on **poc-apps** first → nprd-apps → prd-apps → manager nodes carefully → (optional) OS patch.

Related: [OPS_NOTES.md](OPS_NOTES.md) (pin summary), [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md), PRs [#14](https://github.com/DataKnifeAI/rancher-deploy/pull/14) / [#15](https://github.com/DataKnifeAI/rancher-deploy/pull/15).

---

## 0. PR / Terraform foundation (before any live bump)

| Step | Action | Done |
|------|--------|------|
| 0.1 | Merge **#14** (`feat/rke2-bootstrap-harbor-topology`) — `rke2_version` var, optional registries.yaml (LE Harbor, no custom CA), topology labels, resilient bootstrap | [ ] |
| 0.2 | Merge/rebase **#15** (`feat/rancher-rke2-os-upgrades`) — default pins + `enable_rke2_upgrade` / `enable_os_patch` (both default **false**); `enable_unattended_upgrades` defaults **true** (security-only, no auto-reboot) | [ ] |
| 0.3 | In live `terraform/terraform.tfvars`, **do not** leave final pins active for the first apply after merge | [ ] |

**How #15 interacts with stepped upgrades**

- Repo defaults become `rancher_version = "v2.15.0"` and `rke2_version = "v1.36.2+rke2r1"`.
- For live stepped work, **override** in `terraform.tfvars` (or `-var`) to the *current* step only — e.g. keep `rancher_version = "v2.13.3"` until that Helm upgrade succeeds.
- Keep `enable_rke2_upgrade = false` and `enable_os_patch = false` until the canary phase explicitly enables them (prefer **manual** script on poc IPs; see §5).
- Changing `rke2_version` alone only affects **new** VMs; existing nodes need the day-2 script or `enable_rke2_upgrade`.

**Chart repo note (Rancher 2.15):** `deploy-rancher.sh` installs from `rancher-stable`. As of this writing, `v2.15.0` is on `rancher-latest` but may not yet be indexed on `rancher-stable`. Before the final Rancher step, verify:

```bash
helm repo update
helm search repo rancher-stable/rancher --versions | head -10
helm search repo rancher-latest/rancher --versions | head -5
```

If `2.15.0` is missing from stable, either wait for stable publish or temporarily helm-upgrade from `rancher-latest` (document the override; prefer patching the script only for that step).

---

## 1. Version ladder (exact strings)

Re-verify latest patch of each minor immediately before that step (`helm search` / RKE2 channels). Strings below are the intended pins as of 2026-07-31.

### Rancher (`rancher_version` / Helm `--version`)

| Step | Set in tfvars / helm | Notes |
|------|----------------------|--------|
| Live | `v2.13.1` | Current |
| R1 | `v2.13.3` | Latest patch of 2.13 on charts (confirm) |
| R2 | `v2.14.3` | Latest 2.14 on charts; if `v2.14.4` appears, use that instead before 2.15 |
| R3 | `v2.15.0` | Required for RKE2 1.36; may need `rancher-latest` until stable catches up |

Supported rule: **latest patch of current minor → latest patch of next minor**. Do not jump `v2.13.1` → `v2.15.0`.

### RKE2 (`rke2_version` / `INSTALL_RKE2_VERSION`)

| Step | Pin string | When |
|------|------------|------|
| Live | `v1.34.3+rke2r1` | Current on all clusters |
| K1 | `v1.35.6+rke2r1` | Channel `v1.35` / former stable; **required** mid step |
| K2 | `v1.36.2+rke2r1` | Target; only after Rancher `v2.15.0` |

Optional same-minor warm-up on canary: `v1.34.9+rke2r1` before K1 (not required by skew policy).

### cert-manager (`cert_manager_version` / Helm `--version`)

| Step | Pin | Where |
|------|-----|--------|
| Live manager | `v1.16.5` | cattle local / manager |
| Live apps | `v1.19.2` | nprd / prd / poc |
| CM-M1 | `v1.19.2` | Manager catch-up before/during Rancher steps |
| CM-A1 | `v1.21.1` | Apps (poc first), then nprd/prd; manager too before RKE2 1.36 |

`v1.21.x` supports Kubernetes 1.33–1.36; `v1.20.x` tops out at 1.35 — bump to **1.21** before any cluster goes to RKE2 1.36.

Single Terraform var `cert_manager_version` feeds manager deploy + all apps modules. Prefer **targeted Helm** for canary CM so you do not force every cluster in one apply.

---

## 2. What NOT to do

| Do not | Why |
|--------|-----|
| Set `enable_rke2_upgrade=true` with `rke2_version` jumping `1.34` → `1.36` | Script upgrades **all** node IPs to one pin; skips 1.35; no drain |
| Skip RKE2 `v1.35.x` | Kubernetes minor skew — control plane/workers must step one minor |
| Upgrade downstream RKE2 (or manager RKE2) **before** Rancher can manage that K8s line | 2.14.x certifies through 1.35; **1.36 needs Rancher 2.15+** |
| Apply merged #15 defaults in one shot on live | Would aim Helm/bootstrap at final pins without stepping |
| Enable `enable_os_patch` + auto-reboot across all clusters mid-upgrade | Broad blast radius; do OS after poc RKE2 success |
| Wipe `terraform.tfstate` to “fix” versions | Use pins + gated scripts / targeted helm |
| Commit secrets (`terraform.tfvars`, `.keys/`, `config/`) | Keep out of git |

---

## 3. Phase A — Backups & freeze

| Step | Action | Done |
|------|--------|------|
| A.1 | Snapshot / backup etcd (or full VM snapshots) for **manager** control-plane VMs | [ ] |
| A.2 | Snapshot / backup **poc-apps** (canary) control-plane VMs | [ ] |
| A.3 | Export kubeconfigs: `~/.kube/rancher-manager.yaml`, `poc-apps.yaml`, `nprd-apps.yaml`, `prd-apps.yaml` | [ ] |
| A.4 | Record live versions (paste into change ticket) | [ ] |
| A.5 | Confirm SSH deploy key works to manager + poc nodes (see [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md)) | [ ] |
| A.6 | Freeze non-essential applies / app deploys on poc during canary window | [ ] |

```bash
# Record live versions
kubectl --context local -n cattle-system get deploy rancher -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context local -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
for ctx in poc-apps nprd-apps prd-apps; do
  echo "== $ctx =="
  kubectl --context "$ctx" get nodes -o wide
  kubectl --context "$ctx" -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
done
```

**Abort if:** etcd/VM backup failed, SSH to canary/manager broken, or any cluster already NotReady.

---

## 4. Phase B — Manager cert-manager → stepped Rancher → apps cert-manager

### B1. Manager cert-manager → `v1.19.2`

Prefer Helm on manager (avoids dragging apps modules):

```bash
export KUBECONFIG=~/.kube/rancher-manager.yaml   # or --context local
helm repo update
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --version v1.19.2 \
  --wait --timeout 10m
kubectl -n cert-manager get pods
kubectl -n cattle-system get pods
```

Or set `cert_manager_version = "v1.19.2"` and:

```bash
cd terraform
terraform apply -target=module.rancher_deployment
```

(Remember `deploy-rancher.sh` also (re)applies Rancher at current `rancher_version` — keep Rancher pin at live until B2.)

| Checkpoint | Pass criteria | Done |
|------------|---------------|------|
| CM pods | All Running / Ready | [ ] |
| Rancher | UI/API still up; `cattle-system` healthy | [ ] |
| Downstream | Clusters still Active in Rancher UI | [ ] |

**Abort if:** cert-manager webhook failures, Rancher pods CrashLoop, or API unreachable >15m.

### B2. Rancher steps (manager only)

For each row: set **only** that `rancher_version` in tfvars (leave `rke2_version` at live `v1.34.3+rke2r1` until §5), then apply Rancher only.

| # | `rancher_version` | Apply | Validate | Done |
|---|-------------------|-------|----------|------|
| B2a | `v2.13.3` | `-target=module.rancher_deployment` or helm upgrade | UI login; downstream Active; `kubectl get nodes` on manager | [ ] |
| B2b | `v2.14.3` | same | same + Agents reconnect | [ ] |
| B2c | `v2.15.0` | same (see chart-repo note) | same; confirm Settings show 2.15 | [ ] |

Example Helm (if not using Terraform for a step):

```bash
export KUBECONFIG=~/.kube/rancher-manager.yaml
helm repo update
# Prefer stable when available; else rancher-latest for 2.15.0 only.
# From 2.14 onward use --reset-then-reuse-values (not plain --reuse-values)
# and set networkExposure.type=ingress explicitly.
helm upgrade rancher rancher-stable/rancher \
  --namespace cattle-system \
  --reset-then-reuse-values \
  --set hostname="$RANCHER_HOSTNAME" \
  --set replicas=3 \
  --set ingress.tls.source=secret \
  --set networkExposure.type=ingress \
  --version 2.14.3 \
  --wait --timeout 15m
```

| After each Rancher step | Done |
|-------------------------|------|
| Rancher UI loads; admin login works | [ ] |
| Local cluster Ready; no stuck cattle-cluster-agent on downstream | [ ] |
| Sample workload on poc still Running | [ ] |

**Abort if:** Rancher install fails, UI down after settle, or downstream clusters stuck Unavailable. Roll back Helm to previous chart version (restore from backup if etcd damaged).

### B3. Apps cert-manager → `v1.21.1` (poc first)

Canary Helm on poc only:

```bash
export KUBECONFIG=~/.kube/poc-apps.yaml
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --version v1.21.1 \
  --wait --timeout 10m
kubectl --context poc-apps -n cert-manager get pods
# Spot-check Certificates / sample Ingress TLS if used
```

Then nprd → prd → manager (manager to `v1.21.1` before manager RKE2 1.36). When aligning Terraform: `cert_manager_version = "v1.21.1"` and targeted module applies, or continue Helm.

| Checkpoint | Done |
|------------|------|
| poc CM `v1.21.1`, pods Ready | [ ] |
| Existing Certificates still Ready (if any) | [ ] |
| nprd / prd / manager CM upgraded before their RKE2 1.36 step | [ ] |

---

## 5. Phase C — RKE2 canary on **poc-apps** (then nprd → prd → manager)

### Why not `enable_rke2_upgrade` for canary

`null_resource.rke2_upgrade_nodes` SSHes **every** manager + apps IP in `local.all_rke2_node_ips`. For poc-first, call the script with **poc IPs only**.

Live poc-apps node IPs (verify before use):

```text
192.168.14.130  poc-apps-1          (control-plane)
192.168.14.131  poc-apps-2
192.168.14.132  poc-apps-3
192.168.14.133–138  workers
```

### Per-node procedure (each version step)

1. Cordon + drain one node (`kubectl drain --ignore-daemonsets --delete-emptydir-data`).
2. Run installer for **one** IP.
3. Uncordon; wait Ready + matching version.
4. Next node (CP first is fine if etcd healthy; keep quorum — one CP at a time).

```bash
# From repo root — example single node to 1.35.6
bash scripts/upgrade-rke2-nodes.sh .keys/id_rsa 'v1.35.6+rke2r1' 192.168.14.130
```

### C1. poc-apps → `v1.35.6+rke2r1`

| Step | Action | Done |
|------|--------|------|
| C1.1 | Confirm Rancher is already `v2.14.3+` (1.35 OK) or `v2.15.0` | [ ] |
| C1.2 | Confirm poc cert-manager ≥ `v1.20` / prefer `v1.21.1` | [ ] |
| C1.3 | Set tfvars `rke2_version = "v1.35.6+rke2r1"` for **documentation / new nodes only**; keep `enable_rke2_upgrade=false` | [ ] |
| C1.4 | Roll all poc nodes via script (drain yourself) | [ ] |

**Validate poc after C1**

```bash
kubectl --context poc-apps get nodes -o wide
# all Ready, VERSION v1.35.6+rke2r1
kubectl --context poc-apps get pods -A | grep -vE 'Running|Completed'
# CSI / storage smoke
kubectl --context poc-apps get csidrivers
kubectl --context poc-apps get storageclass
kubectl --context poc-apps get pods -A | grep -iE 'democratic|csi|truenas'
# optional: create/delete a tiny PVC on default SC and mount in a busybox pod
```

| Checkpoint | Done |
|------------|------|
| All poc nodes Ready on `v1.35.6+rke2r1` | [ ] |
| Rancher shows poc cluster Active / correct K8s | [ ] |
| Sample app pods Running | [ ] |
| CSI driver + StorageClass healthy; test PVC OK | [ ] |

**Abort if:** etcd loss, nodes stuck NotReady >30m, CSI attach failures, or Rancher marks cluster unavailable. Do **not** start 1.36 or other clusters.

### C2. poc-apps → `v1.36.2+rke2r1`

| Preflight | Done |
|-----------|------|
| Rancher **`v2.15.0`** live | [ ] |
| poc cert-manager **`v1.21.1`** | [ ] |
| C1 validation green for ≥ soak window (suggest ≥24h if prod-like risk) | [ ] |

```bash
# tfvars documentation pin
rke2_version = "v1.36.2+rke2r1"
# still: enable_rke2_upgrade = false

bash scripts/upgrade-rke2-nodes.sh .keys/id_rsa 'v1.36.2+rke2r1' <poc-ip>
# repeat drained rolling for all poc IPs
```

Repeat the same validation block as C1 (nodes / UI / pods / CSI).

**Note:** RKE2 1.36 defaults Traefik for *new* clusters; existing ingress-nginx installs should remain. Watch Ingress / Gateway behavior on poc after upgrade.

### Poc canary results & learnings (2026-07-31)

**Verdict: GO to promote** nprd → prd → manager RKE2 (same drain + script ladder). Do **not** skip manager CM → `v1.21.1` before manager RKE2 1.36.

| Component | Live after canary |
|-----------|-------------------|
| Rancher (manager) | `v2.15.0` (3/3 Ready; UI HTTPS 200) |
| Manager RKE2 | still `v1.34.3+rke2r1` |
| Manager cert-manager | `v1.19.2` (bump to `v1.21.1` before manager 1.36) |
| poc-apps RKE2 | all 9 nodes Ready `v1.36.2+rke2r1`; `/readyz` pass |
| poc cert-manager | `v1.21.1` (controller/cainjector/webhook Ready; ClusterIssuer Ready) |
| nprd / prd RKE2 | still `v1.34.3+rke2r1` (untouched) |
| Downstream in Rancher | poc / nprd / prd / local all `Ready=True`, `Connected=True`; poc reports `v1.36.2+rke2r1` |

**Promote procedure fixes (apply these on nprd/prd/manager):**

1. **Rancher Helm (already done on manager):** from 2.14 use `--reset-then-reuse-values` + `--set networkExposure.type=ingress` (plain `--reuse-values` omitted new chart keys and failed render).
2. **Rancher 2.15 chart source:** `v2.15.0` was on `rancher-latest` only — not yet on `rancher-stable`. Re-check stable before future upgrades; document override if still missing.
3. **`scripts/upgrade-rke2-nodes.sh`:** avoid `list-unit-files \| grep -q` under `pipefail` (SIGPIPE abort); restart the **enabled/active** unit (`rke2-server` vs `rke2-agent`) — both unit files ship in the tarball so `systemctl cat` alone can pick the wrong one. Do **not** force `INSTALL_RKE2_TYPE` from a stale probe if the official installer already preserves role.
4. **Manager CM gate:** leave manager at CM `v1.19.2` until just before manager RKE2 1.36, then Helm to `v1.21.1` (same as poc B3).
5. **Backups:** Rancher Backup → RustFS S3 returned Access Denied; relied on on-demand etcd snapshots (`pre-upgrade-poc-canary-20260731` on manager + poc). Fix RustFS creds/bucket before the next window; still take etcd snapshots per cluster before each RKE2 ladder.
6. **Apps CM before each cluster’s 1.36:** nprd/prd are still on CM `v1.19.2` — bump each to `v1.21.1` before that cluster’s C2 (1.36) step (same as poc).

**Verification notes (poc post-C2):**

| Area | Result |
|------|--------|
| Core (etcd, apiserver, scheduler, CCM, CoreDNS, canal 9/9, kube-proxy 9/9, ingress-nginx 9/9) | Healthy |
| cattle-cluster-agent 2/2, fleet-agent, rancher-webhook | Ready; brief metrics discovery flaps during roll settled |
| TrueNAS CSI | CSIDriver present; controller 6/6 + node DS Ready; only PVC Bound (prometheus) |
| Operators | cnpg, mongodb, ARC, envoy-gateway Running |
| cert-manager TLS | ClusterIssuer Ready; TLS secrets present (wildcard). No Certificate CRs listed on poc at verify time (manager Certificates Ready) |
| Pre-existing bad pod | `cka-troubleshooting/web-server` ImagePullBackOff (`nginx:1.21-invalid`) — intentional lab, ignore |
| OpenSearch operator | Manager container Running; sidecar `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0` **ImagePullBackOff** (image **not found** on gcr). nprd/prd still 2/2 only because the image is node-cached — expect the same pull failure after drain/reboot. Fix (retarget image / upgrade operator) before or during promote |
| Manager | Rancher 3/3 `v2.15.0`, CM `v1.19.2`, fleet Ready; `healthz` ok (`readyz` not exposed on this manager API) |
| Non-blocking noise | `rke2-snapshot-controller` restarts during roll (Ready); kube-vip high historical restart counts but Running; fleet-default `gitops-core` Init:Error age 195d (pre-existing) |

---

### C3. Promote: nprd → prd → manager

Only after poc C2 is green **and** the learnings above are applied (script fix present; CM 1.21.1 before each cluster’s 1.36; etcd snapshot before roll).

| Order (doc default) | Cluster | RKE2 steps | Extra care | Done |
|---------------------|---------|------------|------------|------|
| 1 | nprd-apps | `1.35.6` then `1.36.2` | Same drain+script pattern | [x] |
| 2 | prd-apps | same | Maintenance window; CSI + prod workloads | [x] |
| 3 | manager (local) | same | **Last**; one CP at a time; Rancher downtime risk; etcd quorum | [x] |

**Live promote order (2026-07-31 / 2026-08-01):** manager → nprd-apps → prd-apps (poc left as canary). Same ladder; manager first per operator request.

Manager: prefer manual script with **only** manager IPs. Avoid `enable_rke2_upgrade=true` until every cluster is already on the target pin and you intentionally want a re-run trigger.

When all clusters match target, set tfvars:

```hcl
rancher_version      = "v2.15.0"
rke2_version         = "v1.36.2+rke2r1"
cert_manager_version = "v1.21.1"
enable_rke2_upgrade  = false
enable_os_patch      = false
```

### Promote results (2026-08-01)

**Verdict: COMPLETE.** All four clusters on target pins. Rancher UI HTTPS 200; downstream Ready+Connected.

| Component | Live after promote |
|-----------|-------------------|
| Rancher (manager) | `v2.15.0` (3/3 Ready; UI HTTPS 200) |
| Manager RKE2 | all 3 CP Ready `v1.36.2+rke2r1` |
| Manager cert-manager | `v1.21.1` |
| poc-apps RKE2 | all 9 Ready `v1.36.2+rke2r1` (unchanged canary) |
| nprd-apps RKE2 | all 9 Ready `v1.36.2+rke2r1` |
| prd-apps RKE2 | all 9 Ready `v1.36.2+rke2r1` |
| cert-manager (all) | `v1.21.1` |
| Downstream in Rancher | poc / nprd / prd / local all `Ready=True`, `Connected=True`, `v1.36.2+rke2r1` |

**Status by phase**

| Cluster | CM → 1.21.1 | Etcd snap | OpenSearch proxy fix | RKE2 1.35.6 | RKE2 1.36.2 | Post-validate |
|---------|-------------|-----------|----------------------|-------------|-------------|---------------|
| manager | [x] | [x] `pre-upgrade-manager-promote-*` | n/a | [x] | [x] | Rancher 3/3, healthz ok |
| nprd-apps | [x] | [x] | [x] → `quay.io/brancz/kube-rbac-proxy:v0.15.0` | [x] | [x] | cattle-agent 2/2, CSIDriver present |
| prd-apps | [x] | [x] | [x] same image | [x] | [x] | cattle-agent 2/2, CSIDriver present |
| poc-apps | [x] (prior) | prior | [x] during promote | [x] prior | [x] prior | left as-is |

**Promote learnings (add to next window):**

1. **Direct kubeconfig for drains:** Rancher-proxied kubeconfigs (`~/.kube/*-apps.yaml`) flap when cattle-cluster-agent is drained. Prefer admin kubeconfig from `/etc/rancher/rke2/rke2.yaml` rewritten to a CP IP for drain/wait loops.
2. **STRICT_VERIFY / agent CA:** After manager RKE2 roll, prd `cattle-cluster-agent` CrashLoopBackOff with `STRICT_VERIFY=true` and missing `/etc/kubernetes/ssl/certs/serverca`. Patched deploy env `STRICT_VERIFY=false` (nprd already false). `apply-system-agent-upgrader-*` Error pods from same CA strict path are noisy but non-blocking once cluster-agent is up.
3. **OpenSearch kube-rbac-proxy:** Patched all apps clusters to `quay.io/brancz/kube-rbac-proxy:v0.15.0` (gcr image not found). Helm release still `opensearch-operator-2.8.0` — re-apply chart values or keep the set-image patch across helm upgrades.
4. **PDB blockers:** nprd Harbor postgres PDBs (`minAvailable: 1`) blocked drains; temporarily `minAvailable: 0` then restore. prd: `coder-postgres-primary` / `high-command-postgres-primary` same pattern. Prefer `--force --disable-eviction` with short timeout when PDB softens are in place.
5. **CSINode NotReady flake:** After CP restart, kubelet can stick `Ready=False` with `failed to initialize CSINode` / API connection refused during boot. Fix: restart `rke2-server`/`rke2-agent` once API is listening.
6. **Workspace branch churn:** Concurrent agents switched git branches mid-run and removed `scripts/upgrade-rke2-nodes.sh` from the working tree. Keep a copy of the script outside the repo (e.g. `/tmp`) for long rolls.
7. **Etcd snapshots:** On-demand snaps taken (`pre-upgrade-manager-promote-*`, `pre-upgrade-nprd-promote-*`, `pre-upgrade-prd-*`). RustFS Rancher Backup still not fixed from canary notes.

---

## 6. Phase D — OS patch (optional, after poc RKE2 success)

Separate from Kubernetes upgrades. Run only after poc C1 or C2 is stable.

**Unattended-upgrades** (security pocket, `Automatic-Reboot false`) is independent: enabled by default for new nodes at bootstrap and for existing nodes via `enable_unattended_upgrades=true` (day-2 SSH). It does **not** replace a deliberate full `enable_os_patch` window.

| Step | Action | Done |
|------|--------|------|
| D.1 | Prefer manual: drain node → `scripts/patch-os-nodes.sh` for that IP → reboot if needed → uncordon | [ ] |
| D.2 | Or set `enable_os_patch=true`, `os_patch_reboot=false`, bump `os_patch_trigger` — still expect to drain yourself; script hits **all** IPs | [ ] |
| D.3 | Do **not** combine OS patch + RKE2 minor bump in the same change window | [ ] |
| D.4 | Confirm unattended-upgrades is present (`/etc/apt/apt.conf.d/50unattended-upgrades`); leave auto-reboot **false** | [ ] |

---

## 7. Rollback / abort criteria

| Symptom | Action |
|---------|--------|
| Helm Rancher upgrade fails | `helm history` / `helm rollback rancher -n cattle-system`; restore previous `rancher_version` |
| cert-manager webhook broken | Rollback chart; restore CM version; do not proceed to Rancher/RKE2 |
| poc node NotReady after RKE2 | Do not upgrade further nodes; check `journalctl -u rke2-server|rke2-agent`; restore VM snapshot if etcd/CP lost |
| CSI broken on poc after RKE2 | Pause promotion; fix mounts/driver before nprd/prd |
| Rancher UI down >15–30m post-upgrade | Rollback Rancher chart; do not start RKE2 1.36 |
| Need full abort mid-fleet | Leave remaining clusters on last known-good minor; document drift in tfvars overrides |

RKE2 **does not** support clean downgrade. Recovery = fix forward, restore VM/etcd backup, or replace node and rejoin at last good version.

---

## 8. Master checklist (poc-first sequence)

| # | Phase | Pin / action | Done |
|---|-------|--------------|------|
| 0 | Merge #14 then #15; override live tfvars to current step | foundation | [ ] |
| 1 | Backups + version inventory + SSH | A | [ ] |
| 2 | Manager CM → `v1.19.2` | B1 | [ ] |
| 3 | Rancher → `v2.13.3` | B2a | [ ] |
| 4 | Rancher → `v2.14.3` | B2b | [ ] |
| 5 | Rancher → `v2.15.0` | B2c | [ ] |
| 6 | poc CM → `v1.21.1` (then other apps / manager) | B3 | [ ] |
| 7 | poc RKE2 → `v1.35.6+rke2r1` + validate CSI | C1 | [ ] |
| 8 | Soak; then poc RKE2 → `v1.36.2+rke2r1` | C2 | [ ] |
| 9 | nprd then prd RKE2 ladder | C3 | [x] |
| 10 | Manager RKE2 ladder (careful) | C3 | [x] |
| 11 | Align tfvars to final pins; flags stay false | cleanup | [x] |
| 12 | Optional OS patch | D | [ ] |

---

## 9. Quick reference — tfvars snippets per stage

**During Rancher stepping (example mid-flight):**

```hcl
rancher_version      = "v2.14.3"          # current step only
rke2_version         = "v1.34.3+rke2r1" # still live on nodes
cert_manager_version = "v1.19.2"
enable_rke2_upgrade  = false
enable_os_patch      = false
```

**During poc RKE2 1.35 canary:**

```hcl
rancher_version      = "v2.15.0"
rke2_version         = "v1.35.6+rke2r1"  # pin for new nodes / docs; upgrade poc via script
cert_manager_version = "v1.21.1"
enable_rke2_upgrade  = false
```

**Final (all clusters upgraded):**

```hcl
rancher_version      = "v2.15.0"
rke2_version         = "v1.36.2+rke2r1"
cert_manager_version = "v1.21.1"
enable_rke2_upgrade  = false
enable_os_patch      = false
```
