# RKE2 certificate rotation runbook

RKE2 leaf certificates (client and server) are valid for 365 days. On the control-plane nodes of every cluster they were due to expire in **January 2027**. This runbook renews them one cluster at a time, poc-apps first. CA certificates (10 years, to 2036) are **not** touched.

**Status: done 2026-10-04.** The certs were renewed by restart during the rolling OS reboots ([UPGRADE_PLAN.md #4](UPGRADE_PLAN.md#executed-2026-10-04-items-16)), not by `rke2 certificate rotate`. Everything now expires **2027-10-05**; poc-apps-1's server certs stay at 2027-09-19. See [Renewal on 2026-10-04](#renewal-on-2026-10-04). The rest of this page is the runbook for next time.

## Renewal on 2026-10-04

Method: restart-triggered renewal. Every server was drained, patched and rebooted one at a time (etcd leader last), so `rke2-server` started inside the 120-day window and renewed every leaf cert on that node. The private keys were reused. Agents reissue their certs on every start, so the agent reboots refreshed those too. Pre-reboot backups: an etcd snapshot per cluster (`~/backups/etcd/pre-reboots-<cluster>-*`) and `/root/rke2-tls-pre-reboot-2026100{4,5}.tgz` on every server.

| Cluster | Server | `:6443` cert notAfter (was) | Now |
|---------|--------|-----------------------------|-----|
| poc-apps | poc-apps-1 (.130) | 2027-09-19 05:26 UTC | unchanged (renewed 2026-09-19, outside the window) |
| | poc-apps-3 (.132) | 2027-01-15 | **2027-10-05 01:39 UTC** |
| | poc-apps-2 (.131, leader) | 2027-01-15 | **2027-10-05 01:44 UTC** |
| nprd-apps | nprd-apps-1 (.110) | 2027-01-08 | **2027-10-05 02:16 UTC** |
| | nprd-apps-3 (.112) | 2027-01-08 | **2027-10-05 02:21 UTC** |
| | nprd-apps-2 (.111, leader) | 2027-01-08 | **2027-10-05 02:38 UTC** |
| prd-apps | prd-apps-2 (.121) | 2027-01-08 | **2027-10-05 03:19 UTC** |
| | prd-apps-3 (.122) | 2027-01-08 | **2027-10-05 03:24 UTC** |
| | prd-apps-1 (.120, leader) | 2027-01-08 | **2027-10-05 03:29 UTC** |
| rancher-manager | rancher-manager-1 (.100) | 2027-01-08 | **2027-10-05 04:11 UTC** |
| | rancher-manager-3 (.102) | 2027-01-08 | **2027-10-05 04:16 UTC** |
| | rancher-manager-2 (.101, leader) | 2027-01-08 | **2027-10-05 04:22 UTC** |

`sudo rke2 certificate check` afterwards showed:
- all 17 leaf certs on every server at 2027-10-05 (poc-apps-1: 13 at 2027-09-19 and 4 at 2027-10-05);
- the agent certs on the sampled workers (one per cluster) at 2027-10-05;
- no warnings.

After each cluster's servers:
- the break-glass `~/.kube/<cluster>-rke2.yaml` was re-fetched from a renewed server, with its client cert now expiring 2027-10-05 (old files kept as `~/.kube/<cluster>-rke2.yaml.bak-<ts>`);
- `gitops-core/scripts/create-cert-sync-kubeconfig-secret.sh` was re-run;
- a manual `cert-sync` job synced all four clusters.

Old `system:admin` client certs (earlier `rke2.yaml` copies) remain valid until their own `notAfter` (2027-01-08, poc 2027-09-19); nothing was revoked.

**Next renewal.** Any rke2-server restart inside the 120-day window renews again:
- from **2027-05-22** on poc-apps-1;
- from **2027-06-07** everywhere else.

Plan a rolling reboot or RKE2 upgrade between 2027-06-07 and **2027-09-01**, or run `rke2 certificate rotate` at any time.

## Expiries before the renewal

Read on 2026-10-04 (before the renewal) with `sudo rke2 certificate check --output table` on every server and one agent per cluster (all nodes run `v1.36.2+rke2r1`).

| Cluster | Node(s) | Server leaf certs¹ | kubelet / kube-proxy / rke2-controller | rke2 last started |
|---------|---------|--------------------|----------------------------------------|-------------------|
| rancher-manager | rancher-manager-1 (.100) | **2027-01-08 06:35 UTC** | 2027-09-09 | 2026-09-09 |
| | rancher-manager-2, -3 (.101, .102) | **2027-01-08 06:53 UTC** | 2027-09-09 | 2026-09-09 |
| nprd-apps | nprd-apps-1 (.110) | **2027-01-08 07:18 UTC** | 2027-09-09 | 2026-09-09 |
| | nprd-apps-2, -3 (.111, .112) | **2027-01-08 07:36 UTC** | 2027-09-09 (-2), 2027-08-01 (-3) | 2026-09-09 / 2026-08-01 |
| | workers (sample nprd-apps-worker-1) | — | 2027-09-09 | 2026-09-09 |
| prd-apps | prd-apps-1 (.120) | **2027-01-08 07:18 UTC** | 2027-08-01 | 2026-08-01 |
| | prd-apps-2, -3 (.121, .122) | **2027-01-08 07:36 UTC** | 2027-08-01 | 2026-08-01 |
| | workers (sample prd-apps-worker-1) | — | 2027-08-01 | 2026-08-01 |
| poc-apps | poc-apps-1 (.130) | 2027-09-19 (already renewed) | 2027-09-19 | 2026-09-19 |
| | poc-apps-2, -3 (.131, .132) | **2027-01-15 03:34 UTC** | 2027-09-09 | 2026-09-09 |
| | workers (sample poc-apps-worker-1) | — | 2027-09-09 | 2026-09-09 |

¹ `serving-kube-apiserver` (the `:6443` cert), `client-kube-apiserver`, `client-admin` (what `rke2.yaml` embeds), `client-auth-proxy`, etcd `client` / `server-client` / `peer-server-client`, `client-controller`, `kube-controller-manager`, `client-scheduler`, `kube-scheduler`, `client-supervisor`, `client-rke2-cloud-controller`.

CAs: `rke2-*-ca@…` valid to 2036-01-06 (manager, nprd, prd) and 2036-01-13 (poc). Each cluster has its own CAs (nprd and prd CA names share a timestamp but the keys differ).

What the table shows about RKE2's behaviour:

- **Agent-side certs** (kubelet, kube-proxy, rke2-controller) are reissued every time rke2 starts on a node. They are fine until August 2027 and need no action in this window.
- **Server leaf certs** are renewed on start **only if they are expired or within 120 days of expiry** (90 days before the May 2025 releases). The 2026-09-09 restarts were 121+ days before 2027-01-08, so nothing was renewed. poc-apps-1 restarted on 2026-09-19, 118 days before 2027-01-15, and renewed everything. Since about 2026-09-10 every remaining server is inside the window, so **any rke2-server restart from now on renews that node's certs** — including unplanned ones such as OS-patch reboots.

## Method: `rke2 certificate rotate` vs restart

| | Restart-triggered renewal | `rke2 certificate rotate` |
|---|---|---|
| Command | `systemctl restart rke2-server` | `systemctl stop rke2-server && rke2 certificate rotate && systemctl start rke2-server` |
| When it works | Only while certs are expired or within 120 days of expiry (true for all remaining servers until the January 2027 expiry) | Any time |
| Keys | **Reuses** the existing private keys and extends the certs | Generates **new** certs and keys |
| Scope | Every leaf cert within the window on that node | All leaf certs on that node (or a subset with `--service admin,api-server,…`) |
| Order | Any; one node at a time | Any since the January 2025 releases (before that: etcd, control plane, agents). Still one node at a time |

Source: [RKE2 docs: Certificate Management](https://docs.rke2.io/security/certificates). `rke2 certificate check|rotate|rotate-ca` all exist in v1.36.2 (`rke2 certificate --help`).

**Recommendation: `rke2 certificate rotate`** on each server. It doesn't depend on the date, it gives fresh keys, and it's the procedure the RKE2 docs describe. Restart-only renewal is an acceptable fallback (that's how poc-apps-1 got renewed), and it is what happens if a node reboots before the window.

Neither method revokes anything. Kubernetes has no CRL, so old `system:admin` client certs (old `rke2.yaml` copies, the old break-glass files, the old `cert-sync-kubeconfig`) stay valid until their own `notAfter` (2027-01-08). Revoking them would take a CA rotation (`rke2 certificate rotate-ca`), which is out of scope.

## Recommended window

Superseded: the 2026-10-04 reboots did the renewal. The plan below was for the January 2027 expiry.

- **Prerequisite:** the TrueNAS CSI v0.22 rollout and the Terraform state repair (in progress 2026-10-04) are finished, with at least one quiet week afterwards. No `terraform apply` runs during the window.
- **poc-apps:** Saturday **2026-10-24** (only poc-apps-2 and -3 need it).
- **nprd-apps:** Saturday **2026-10-31**.
- **prd-apps**, then **rancher-manager** in the same session or the next weekend: Saturday **2026-11-07** (fallback 2026-11-14).
- **Hard stop:** everything done by **2026-12-01**, leaving five weeks of slack before the first expiry (rancher-manager-1, **2027-01-08 06:35 UTC**) and avoiding the holidays.

Per cluster, budget about 30 minutes for pre-checks and snapshot, and about 10 minutes per server.

## Pre-checks (per cluster)

Use the break-glass kubeconfigs (`~/.kube/<cluster>-rke2.yaml`, see [CLUSTER_ACCESS_AND_SSO.md § Fallback](CLUSTER_ACCESS_AND_SSO.md#fallback-and-break-glass)), not Rancher contexts. They talk to `:6443` directly and don't flap when cattle-cluster-agent moves.

```bash
CLUSTER=poc-apps                       # poc-apps | nprd-apps | prd-apps | rancher-manager
export KUBECONFIG=~/.kube/$CLUSTER-rke2.yaml
SSH="ssh -i .keys/id_rsa -o BatchMode=yes"
SERVERS="192.168.14.131 192.168.14.132"  # poc: .131 .132 (skip .130) | nprd: .110-.112 | prd: .120-.122 | manager: .100-.102
ETCD_POD=etcd-poc-apps-2               # any etcd-<server-node> pod of this cluster

# 1. Nodes and apiserver
kubectl get nodes -o wide
kubectl get --raw '/readyz?verbose' | grep -E 'etcd|passed'

# 2. etcd: all members healthy; note the leader (IS LEADER) and rotate it last
ETCDCTL="etcdctl --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
kubectl -n kube-system exec $ETCD_POD -- $ETCDCTL endpoint health --cluster -w table
kubectl -n kube-system exec $ETCD_POD -- $ETCDCTL endpoint status --cluster -w table

# 3. On-demand etcd snapshot, then copy it off the node
FIRST=${SERVERS%% *}
$SSH ubuntu@$FIRST "sudo rke2 etcd-snapshot save --name pre-cert-rotation-$CLUSTER-$(date +%Y%m%d)"
$SSH ubuntu@$FIRST 'sudo rke2 etcd-snapshot ls' | grep pre-cert-rotation
#   scp the file from /var/lib/rancher/rke2/server/db/snapshots/ to the workstation (sudo cp + chown to ubuntu first)

# 4. Back up the on-disk certs/keys on every server (stays on the node; root-only)
for n in $SERVERS; do
  $SSH ubuntu@$n "sudo tar czf /root/rke2-tls-pre-rotation-$(date +%Y%m%d).tgz \
    /var/lib/rancher/rke2/server/tls /var/lib/rancher/rke2/agent/*.crt /var/lib/rancher/rke2/agent/*.key \
    /etc/rancher/rke2/rke2.yaml && sudo rke2 certificate check --output table | grep -v CertSign"
done

# 5. Rancher sees the cluster Active and the agent is healthy (before and after)
kubectl --kubeconfig ~/.kube/rancher-manager-rke2.yaml get clusters.management.cattle.io \
  -o custom-columns=ID:.metadata.name,NAME:.spec.displayName,READY:'.status.conditions[?(@.type=="Ready")].status'
kubectl -n cattle-system get deploy cattle-cluster-agent
```

Also confirm: free disk on `/` (all servers were 32–57% used on 2026-10-04), no `terraform apply` or CSI work running, and you can reach every node over SSH.

## Rotation (servers, one at a time)

Order inside a cluster: etcd followers first, the etcd leader last. Never start the next node until the previous one is fully healthy — losing two of three etcd members loses quorum.

```bash
NODE=192.168.14.131
$SSH ubuntu@$NODE 'sudo systemctl stop rke2-server && sudo rke2 certificate rotate && sudo systemctl start rke2-server'
```

`systemctl stop rke2-server` leaves workload containers running (`KillMode=process`); the static control-plane pods on that node restart with the new certs. Expect a short apiserver and etcd member blip for that node only, which is why `<cluster>.dataknife.net` (round-robin over three nodes) is used. `rke2 certificate rotate` may also leave a timestamped copy of the old files under `/var/lib/rancher/rke2/server/`; rely on the tarball from pre-check 4.

Wait for and verify before moving on:

```bash
kubectl get node <node-name> -w                       # Ready again
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=<node-name> | grep -E 'etcd|kube-apiserver|controller|scheduler'
kubectl -n kube-system exec $ETCD_POD -- $ETCDCTL endpoint health --cluster -w table
echo | openssl s_client -connect $NODE:6443 2>/dev/null | openssl x509 -noout -enddate   # ~one year out
$SSH ubuntu@$NODE 'sudo rke2 certificate check --output table | grep -v CertSign'          # no WARNING rows
```

**Agents:** no action required in this window (their certs run to 2027-08-01 / 2027-09-09 and are reissued on every agent start, e.g. the next RKE2 upgrade or OS-patch reboot). To refresh them anyway: `sudo systemctl restart rke2-agent` one node at a time, waiting for `Ready`. Since the 2026-10-04 reboots every agent's certs run to 2027-10-05; put **2027-09-01** on the calendar as the latest date for a rolling agent restart if none has happened by then.

## After each cluster

The CAs don't change, so nothing that only pins a CA breaks. What needs refreshing are copies of the old `system:admin` client cert. They keep working until 2027-01-08, but refresh them the same day:

1. **Break-glass kubeconfig** — re-fetch `~/.kube/<cluster>-rke2.yaml` ([procedure](CLUSTER_ACCESS_AND_SSO.md#fallback-and-break-glass)) from a rotated server, and check the client cert's `notAfter` is about one year out.
2. **gitops-core `cert-sync-kubeconfig`** — after re-fetching, run `gitops-core/scripts/create-cert-sync-kubeconfig-secret.sh` (it rebuilds the Secret from all four `~/.kube/<cluster>-rke2.yaml` files and checks `/readyz` for each), then run the job and check that it succeeds:
   ```bash
   kubectl --kubeconfig ~/.kube/rancher-manager-rke2.yaml -n cert-manager create job --from=cronjob/cert-sync cert-sync-manual-$(date +%s)
   kubectl --kubeconfig ~/.kube/rancher-manager-rke2.yaml -n cert-manager get jobs -l purpose=cert-sync
   ```
   The job now exits non-zero if any cluster fails, so `Complete` means every cluster synced.
3. **Rancher ↔ downstream** — the downstream clusters are imported (`c-…` IDs). Rancher reaches them through the outbound cattle-cluster-agent tunnel using a service-account token and the cluster CA, so leaf rotation doesn't affect it. Still confirm the cluster is `Active` in Rancher and `cattle-cluster-agent` is `Running`. After the **rancher-manager** servers, check every downstream `cattle-cluster-agent`. The 2026-08 manager roll left prd's agent in CrashLoopBackOff with `STRICT_VERIFY=true` ([UPGRADE_PLAN.md](UPGRADE_PLAN.md) promote learnings). That is about Rancher's own CA, not RKE2's, but watch for it.
4. **Terraform `~/.kube/<cluster>.yaml`** — if Terraform add-on steps need RKE2 admin access there, re-pull with Terraform's `get_kubeconfig` (or the same fetch) once the Terraform work allows it. Rancher-proxied files at those paths are unaffected.
5. **Other copies** — anything else that embeds an `rke2.yaml` client cert (CI secrets, other workstations) must be re-fetched before 2027-01-08.

Final check after all clusters: no `CertificateExpirationWarning` events newer than the rotation, and update the [cert calendar](CLUSTER_ACCESS_AND_SSO.md#certificate-and-expiry-calendar) with the new expiry dates (next due about 2027-10/11).

```bash
for c in rancher-manager nprd-apps prd-apps poc-apps; do
  echo "== $c"; kubectl --kubeconfig ~/.kube/$c-rke2.yaml get events -A --field-selector reason=CertificateExpirationWarning \
    -o custom-columns=NODE:.involvedObject.name,LAST:.lastTimestamp --no-headers | sort -k2 | tail -3
done
```

## Rollback

Leaf rotation is low risk: the CAs and the trust between components don't change. If a node doesn't come back:

1. Read `journalctl -u rke2-server -e` on that node. Typical causes are a port conflict or a stuck static pod, not the certs.
2. **Restore that node's old certs:** `sudo systemctl stop rke2-server`, `sudo tar xzf /root/rke2-tls-pre-rotation-<date>.tgz -C /`, `sudo systemctl start rke2-server`. The old certs are valid until January 2027, so this buys time.
3. **etcd member broken but quorum intact** (two of three healthy): don't touch the others. Fix or remove and re-join the member (`etcdctl member remove`, wipe `/var/lib/rancher/rke2/server/db` on that node, start rke2-server so it re-joins).
4. **Quorum lost (last resort):** on one server, `rke2 server --cluster-reset --cluster-reset-restore-path=<pre-cert-rotation snapshot>`, then re-join the other servers per the [RKE2 backup/restore docs](https://docs.rke2.io/datastore/backup_restore). This rolls the cluster state back to the snapshot.

Don't rotate further nodes or clusters until the failed one is understood.

## Related

- [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md) — break-glass kubeconfigs, certificate and expiry calendar
- [UPGRADE_PLAN.md](UPGRADE_PLAN.md) — RKE2 upgrade runbook (an RKE2 upgrade restarts rke2 and so also renews certs inside the 120-day window)
- [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md) — SSH keys and node access
- gitops-core `scripts/create-cert-sync-kubeconfig-secret.sh` — rebuilds the cert-sync kubeconfig from the break-glass files
