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

The VM module injects the **matching public key** from `${ssh_private_key}.pub` into cloud-init (`keys = [file("${var.ssh_private_key}.pub")]` in `terraform/modules/proxmox_vm`). There is no separate `ssh_public_key` variable.

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

Kubeconfigs after a successful apply typically land at:

- `~/.kube/rancher-manager.yaml`
- `~/.kube/nprd-apps.yaml`
- `~/.kube/prd-apps.yaml`
- `~/.kube/poc-apps.yaml`

## Recover SSH without replacing VMs

If nodes no longer accept your current key but **kubectl still works**, inject the new public key onto the host filesystem via a privileged node debug session (no Proxmox console required).

Prerequisites: cluster-admin (or equivalent) on the target cluster; `kubectl debug` / ephemeral containers enabled.

```bash
# One node example — repeat per Ready node / context
export KUBECONFIG=~/.kube/prd-apps.yaml   # or use --context=
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

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — SSH permission and IPS issues
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — first-time deploy
