# SSH keys and cluster access

Terraform reaches every RKE2 node over SSH (token fetch, kubeconfig pull, remote-exec). Losing that key breaks `terraform apply` even if Rancher and kubectl still work.

## Repo convention: `.keys/`

- Store the deploy key pair in **`.keys/`** at the repo root (e.g. `.keys/id_rsa` + `.keys/id_rsa.pub`).
- **`.keys/` is gitignored** — never commit private keys.
- Point Terraform at the private key:

```hcl
# terraform/terraform.tfvars
ssh_private_key = "/mnt/game2/git/rancher-deploy/.keys/id_rsa"
# or: ssh_private_key = "${path relative to where you run terraform}/../.keys/id_rsa"
```

The VM module injects the **matching public key** from `${ssh_private_key}.pub` into cloud-init (`keys = [trimspace(file("${var.ssh_private_key}.pub"))]` in `terraform/modules/proxmox_vm`). There is no separate `ssh_public_key` variable. `trimspace` avoids bpg/proxmox `illegal base64 data` failures from trailing newlines in `.pub` files.

Generate a new pair (example):

```bash
mkdir -p .keys
ssh-keygen -t ed25519 -f .keys/id_rsa -N "" -C "rancher-deploy"
chmod 600 .keys/id_rsa
```

## Day-to-day access

```bash
ssh -i .keys/id_rsa ubuntu@<node-ip>
```

**Break-glass RKE2 admin kubeconfigs** (pulled over SSH from `/etc/rancher/rke2/rke2.yaml`; `system:masters` client certs; independent of Rancher and Authentik; cluster-admin; expire with the RKE2 leaf certs):

- `~/.kube/rancher-manager-rke2.yaml` → `https://manager.dataknife.net:6443`
- `~/.kube/nprd-apps-rke2.yaml` → `https://nprd-apps.dataknife.net:6443`
- `~/.kube/prd-apps-rke2.yaml` → `https://prd-apps.dataknife.net:6443`
- `~/.kube/poc-apps-rke2.yaml` → `https://poc-apps.dataknife.net:6443`

Use them for break-glass, upgrade drains, and infra automation (e.g. the gitops-core `cert-sync-kubeconfig` Secret is built from them). They are kept out of `~/.kube/config` on purpose. Fetch / re-fetch procedure (needed after every RKE2 cert rotation): [CLUSTER_ACCESS_AND_SSO.md § Fallback and break-glass](CLUSTER_ACCESS_AND_SSO.md#fallback-and-break-glass).

Terraform's `get_kubeconfig` also writes RKE2 admin kubeconfigs to `~/.kube/<cluster>.yaml` (some add-on steps read those paths), but those files are easily overwritten by Rancher-proxied kubeconfigs — don't rely on them for break-glass. Day-to-day kubectl uses Rancher-login contexts (`kubectl --context prd-apps ...`, SSO via Authentik) — see [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md).

## Recover SSH without replacing VMs

If nodes no longer accept your current key but **kubectl still works**, inject the new public key onto the host filesystem via a privileged node debug session (no Proxmox console required).

Prerequisites: cluster-admin (or equivalent) on the target cluster; `kubectl debug` / ephemeral containers enabled. Any working path is fine: the RKE2 admin kubeconfig, the SSO context, or a `<cluster>-local` break-glass context.

```bash
# One node example — repeat per Ready node / context
export KUBECONFIG=~/.kube/prd-apps-rke2.yaml   # or use --context prd-apps / prd-apps-local
PUB_B64=$(base64 -w0 < .keys/id_rsa.pub)

kubectl debug "node/<node-name>" \
  --image=busybox:1.36 \
  --profile=sysadmin \
  --quiet -- \
  chroot /host sh -c "
    mkdir -p /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chown ubuntu:ubuntu /home/ubuntu/.ssh
    KEY=\$(echo '$PUB_B64' | base64 -d)
    grep -qxF \"\$KEY\" /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo \"\$KEY\" >> /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
  "
```

Then verify:

```bash
ssh -i .keys/id_rsa -o BatchMode=yes ubuntu@<node-ip> 'hostname'
```

Update `ssh_private_key` in `terraform.tfvars` to the key you injected before running Terraform again.

**Alternatives if kubectl debug is blocked:** Proxmox console / cloud-init regenerate, or guest-agent file write — slower, same goal (append pubkey to `/home/ubuntu/.ssh/authorized_keys`).

## Related

- [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md) — kubectl / Rancher login, SSO, break-glass layers
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — SSH permission and IPS issues
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — first-time deploy
