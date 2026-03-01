# Access Secrets (`.keys/`)

All access secrets for this repo live under **`.keys/`** at the repo root. This directory is **git-ignored**; do not use your host system SSH keys (e.g. `~/.ssh/id_rsa`) for deploys.

## Required files

Create the directory and add:

| File | Purpose |
|------|--------|
| `id_rsa` | SSH private key used for VM access (Proxmox-provisioned VMs). |
| `id_rsa.pub` | Matching public key (Terraform injects this into VMs). |
| `rancher-api-token` | Rancher API token (one line, no newline). Used by Terraform and scripts for Rancher API calls. |
| `vm_recovery_password` | Optional. One-line password for the `ubuntu` user on all VMs. Enables Proxmox VM Console (noVNC) login when SSH key is lost. If omitted, set `vm_recovery_password` in `terraform.tfvars` or leave empty. |

## Setup

From the repo root:

```bash
mkdir -p .keys
chmod 700 .keys

# Generate SSH key pair (do not use existing ~/.ssh keys)
ssh-keygen -t ed25519 -f .keys/id_rsa -N "" -C "rancher-deploy"
# or RSA: ssh-keygen -t rsa -b 4096 -f .keys/id_rsa -N "" -C "rancher-deploy"

# Add your Rancher API token (from Rancher: Account → API Tokens)
echo -n "YOUR_TOKEN" > .keys/rancher-api-token
chmod 600 .keys/rancher-api-token

# Optional: VM recovery password for console login
echo -n "your-secure-password" > .keys/vm_recovery_password
chmod 600 .keys/vm_recovery_password
```

Terraform will use, by default:

- **SSH key:** `.keys/id_rsa` (and `.keys/id_rsa.pub`)
- **Rancher token file:** `.keys/rancher-api-token`
- **VM recovery password:** contents of `.keys/vm_recovery_password` if the file exists; otherwise the `vm_recovery_password` variable in `terraform.tfvars`

You can override the SSH key path with the `ssh_private_key` variable in `terraform.tfvars` (e.g. another key under `.keys/`).

## Security

- `.keys/` is listed in `.gitignore`; never commit it or disable the ignore.
- Restrict permissions: `chmod 700 .keys`, `chmod 600 .keys/id_rsa`, `chmod 600 .keys/rancher-api-token`, etc.
- Prefer a dedicated key for this repo rather than your main `~/.ssh` key.
