# Rancher API Token Creation

The Rancher API token is automatically created during the Rancher deployment process. This document explains how the token creation works and how to use it.

> **Scope:** this token is for **Terraform automation** (downstream cluster create/registration). Humans should not use it for kubectl — use the SSO / `rancher token` kubeconfigs in [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md).

## Current facts (verified 2026-10-04)

- **Where Terraform reads it:** `config/.rancher-api-token` (repo root) — the `rancher2` provider (`terraform/provider.tf`) and the cluster-create / cluster-ID `null_resource`s (`terraform/main.tf`). `deploy-rancher.sh` writes this file.
- **Hard-coded path:** `module.rancher_downstream_registration_*` in `terraform/main.tf` uses `rancher_token_file = "/home/lee/git/rancher-deploy/config/.rancher-api-token"`, not this checkout's `config/`. Keep that path in sync (or fix the module call) before a registration apply.
- **`rancher_api_token` in `terraform.tfvars`** is declared in `variables.tf` but not used by any Terraform resource. `create-rancher-api-token.sh` writes it, and `setup-rancher-kubeconfig.sh` reads it for its one-time lookup — copy it into `config/.rancher-api-token` as well.
- **Lifetime:** both scripts request `ttl: 0`, but Rancher's `auth-token-max-ttl-minutes` (`129600` = 90 days) caps every API token, so it **expires after 90 days**.
- **Status:** the token in `terraform.tfvars` and `config/.rancher-api-token` was an expired kubeconfig token (HTTP 401). Create a fresh one before the next downstream registration apply — see [Automation in CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md#automation).
- **SSO:** token creation logs in via the **local** provider (`/v3-public/localProviders/local?action=login`), so it keeps working with Authentik SAML enabled.
- Rancher v2.14+ deprecates v3 tokens (`/v3/tokens`) in favour of `tokens.ext.cattle.io`; the scripts still use v3.

## Overview

When you deploy Rancher using `terraform apply`, the deployment process automatically:

1. Installs Rancher on the manager cluster
2. Waits for Rancher to be fully operational
3. Creates an API token using the bootstrap password
4. Displays the token in the deployment output and saves it to `config/.rancher-api-token`

## How It Works

### During Rancher Deployment

The `deploy-rancher.sh` script (run via Terraform) performs the following steps:

**Step 1: Authenticate with Rancher**
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<bootstrap-password>"}' \
  https://<rancher-url>/v3-public/localProviders/local?action=login
```

**Step 2: Create API Token**
```bash
curl -X POST \
  -H "Authorization: Bearer <temp-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "token",
    "description": "Terraform automation token for downstream cluster registration",
    "ttl": 0,
    "isDerived": false
  }' \
  https://<rancher-url>/v3/tokens
```

### Token Properties

- **Description**: "Terraform automation token for downstream cluster registration"
- **TTL**: requested `0`, capped by `auth-token-max-ttl-minutes` → **90 days** on this Rancher
- **isDerived**: false (not a temporary derivative token)
- **Permissions**: Full access as the `admin` user (unscoped)

## Deployment Workflow

### 1. Deploy Rancher

```bash
# from the repo root
./scripts/apply.sh  # or: terraform apply -auto-approve
```

During deployment, you'll see output like:

```
Module: rancher_cluster / deploy-rancher.sh

✓ Rancher is ready

Testing Rancher URL accessibility...
✓ Rancher is accessible at https://rancher.example.com

Creating Rancher API token for downstream cluster registration...

Step 1: Authenticating with Rancher...
✓ Authenticated with Rancher

Step 2: Creating API token...
✓ API token created successfully

==========================================
Rancher API Token:
==========================================
token-xxxxx:xxxxxxxxxxxxxxxxxxxxxxxxxxxxx

✓ Token saved to: <repo>/config/.rancher-api-token
```

### 2. Enable Registration (token is already in place)

Terraform reads the token from `config/.rancher-api-token`, which the deploy step wrote. Optionally mirror it into `terraform.tfvars` so `setup-rancher-kubeconfig.sh` can use it:

```hcl
# terraform/terraform.tfvars
register_downstream_cluster = true
rancher_api_token = "token-xxxxx:xxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # optional; not read by Terraform resources
```

### 3. Re-apply Terraform

Now that the API token is configured, re-run terraform to enable downstream cluster registration:

```bash
cd terraform
terraform apply -auto-approve
```

This will:
- Create the downstream cluster object in Rancher
- Generate a registration token
- Pass credentials to downstream VMs
- VMs automatically register with Rancher Manager

## Manual Token Creation

If the automatic token creation fails or you need to create another token (e.g. the 90-day token expired), use the `create-rancher-api-token.sh` script. It updates `rancher_api_token` in `terraform.tfvars`; copy it to `config/.rancher-api-token`, which is what Terraform reads:

```bash
# From project root (avoid putting the password in shell history)
read -rsp 'Rancher admin password: ' RANCHER_ADMIN_PASSWORD; echo
./scripts/create-rancher-api-token.sh https://rancher.example.com admin "$RANCHER_ADMIN_PASSWORD"
unset RANCHER_ADMIN_PASSWORD
sed -nE 's/^[[:space:]]*rancher_api_token[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform/terraform.tfvars > config/.rancher-api-token
chmod 600 config/.rancher-api-token
```

## Troubleshooting

### API Token Not Displayed

If the token creation fails during deployment, check the deployment logs:

```bash
# View the full deployment log
tail -f terraform/terraform-*.log

# Look for "Creating Rancher API token" section
grep -A 20 "Creating Rancher API token" terraform/terraform-*.log
```

Common causes:
- Rancher not fully ready when token creation attempted
- Network connectivity issues to Rancher API
- Invalid bootstrap password

**Solution**: Create token manually (see [Manual Token Creation](#manual-token-creation)):
```bash
./scripts/create-rancher-api-token.sh https://rancher.example.com admin "$RANCHER_ADMIN_PASSWORD"
```

### "Failed to authenticate with Rancher API"

This means the bootstrap password was incorrect.

**Solution**: 
1. Verify bootstrap password in `terraform/terraform.tfvars`
2. Check if Rancher is accessible: `curl -k https://rancher.example.com`
3. Create token manually with correct password:
   ```bash
   ./scripts/create-rancher-api-token.sh https://rancher.example.com admin correct-password
   ```

### Downstream Registration Still Not Working

If downstream cluster registration isn't working even with API token set:

1. **Verify API token is valid**:
   ```bash
   # Test token directly
   curl -H "Authorization: Bearer <token>" \
     -k https://rancher.example.com/v3/tokens
   ```

2. **Ensure the token file Terraform reads exists and is valid** (prints the HTTP status only):
   ```bash
   ls -l config/.rancher-api-token
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(cat config/.rancher-api-token)" \
     "https://rancher.example.com/v3/users?me=true"   # 200 = valid, 401 = expired/revoked
   ```

3. **Check register_downstream_cluster is true**:
   ```bash
   grep register_downstream_cluster terraform/terraform.tfvars
   ```

4. **Re-apply Terraform**:
   ```bash
   cd terraform
   terraform apply -auto-approve
   ```

## Accessing Rancher

Once the API token is created and downstream cluster registration is complete:

### Rancher UI

```
URL: https://<rancher-hostname>
SSO: SAML button (provider "Keycloak", backed by Authentik)
Fallback: "Log in with Local User" → admin / <current admin password>
          (initially rancher_password from terraform.tfvars; change it after first login)
```

### kubectl Access

Day-to-day: Rancher-login contexts (`./scripts/setup-rancher-kubeconfig.sh ...`, then `kubectl --context local ...`) — see [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md). Break-glass / automation: the RKE2 admin kubeconfig Terraform writes:

```bash
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl get nodes
kubectl get pods -n cattle-system
```

### API Access

```bash
# Using curl with API token
curl -H "Authorization: Bearer <token>" \
  -k https://rancher.example.com/v3/clusters

# Using Rancher CLI (if installed)
rancher login https://rancher.example.com --token <token>
```

## Security Best Practices

### Protecting the Token

1. **Store in terraform.tfvars** (which should be in `.gitignore`)
   ```bash
   echo "terraform/terraform.tfvars" >> .gitignore
   ```

2. **Never commit to version control**
   ```bash
   # Verify it's in .gitignore
   git status terraform/terraform.tfvars
   # Should show: ignored
   ```

3. **Keep bootstrap password secure**
   - Change it immediately after initial login to Rancher UI
   - Store securely if needed for future use

### Token Rotation

To create a new token and revoke the old one:

Rotate at least every 90 days (the max TTL).

1. **Create new token**:
   ```bash
   ./scripts/create-rancher-api-token.sh https://rancher.example.com admin "$RANCHER_ADMIN_PASSWORD"
   ```

2. **Copy it to `config/.rancher-api-token`** (the script already updated `terraform.tfvars`; see [Manual Token Creation](#manual-token-creation))

3. **Delete old token** via Rancher UI:
   - Avatar → **Account & API Keys**
   - Find the old token
   - Click delete

4. **Re-apply Terraform**:
   ```bash
   cd terraform
   terraform apply -auto-approve
   ```

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [RANCHER_DOWNSTREAM_MANAGEMENT.md](RANCHER_DOWNSTREAM_MANAGEMENT.md) - Downstream cluster registration
- [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md) - kubectl / SSO access, token settings, automation guidance
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues and solutions

## Script Reference

### create-rancher-api-token.sh

Manual token creation script:

```bash
./scripts/create-rancher-api-token.sh <rancher-url> <admin-user> <admin-password>

# Example
./scripts/create-rancher-api-token.sh https://rancher.example.com admin your-password
```

**What it does:**
1. Authenticates with Rancher using admin credentials (local provider)
2. Creates an API token (`ttl: 0`, capped to 90 days by Rancher)
3. Saves token to `rancher_api_token` in `terraform/terraform.tfvars` — **not** to `config/.rancher-api-token`, which Terraform reads; copy it there
4. Displays token for reference (its "TTL: Never expires" message is inaccurate on this Rancher)

### deploy-rancher.sh

Automatic token creation script (called during Terraform apply):

```bash
# Run by Terraform's rancher_cluster module
# Location: terraform/modules/rancher_cluster/deploy-rancher.sh
```

**When it runs:**
- After Rancher Helm chart is installed
- After Rancher deployment is ready
- After Rancher API is accessible

**What it does:**
1. Verifies Rancher is accessible
2. Authenticates with bootstrap password
3. Creates API token
4. Displays token in deployment output
5. Saves it to `config/.rancher-api-token` (mode 600)

## Manual Token Creation via curl

If the automatic token creation fails or you prefer to create the token manually, use these curl commands:

### Quick Test: Verify Rancher Connectivity

```bash
curl -k https://rancher.example.com/health
```

### Full Manual Process

**Step 1: Set Variables**
```bash
RANCHER_URL="https://rancher.example.com"
ADMIN_USER="admin"
ADMIN_PASSWORD="your-bootstrap-password"
```

**Step 2: Get Temporary Authentication Token**
```bash
TEMP_TOKEN=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\"}" \
  -k "$RANCHER_URL/v3-public/localProviders/local?action=login" | \
  jq -r '.token')

echo "Temp Token: $TEMP_TOKEN"
```

**Step 3: Create Permanent API Token**
```bash
API_TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer $TEMP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "token",
    "description": "Terraform automation token",
    "ttl": 0,
    "isDerived": false
  }' \
  -k "$RANCHER_URL/v3/tokens" | \
  jq -r '.token')

echo "API Token: $API_TOKEN"
```

**Step 4: Verify Token Works**
```bash
curl -H "Authorization: Bearer $API_TOKEN" \
  -k "$RANCHER_URL/v3/tokens" | jq '.'
```

### Complete Script

Run the automated test script from project root:

```bash
./scripts/test-rancher-api-token.sh
```

This script handles everything: connectivity testing, authentication, token creation, and verification.

### Useful curl Commands Reference

**List all tokens:**
```bash
curl -H "Authorization: Bearer <api-token>" \
  -k https://rancher.example.com/v3/tokens | jq '.data'
```

**Get clusters:**
```bash
curl -H "Authorization: Bearer <api-token>" \
  -k https://rancher.example.com/v3/clusters | jq '.data'
```

**Create downstream cluster:**
```bash
curl -X POST \
  -H "Authorization: Bearer <api-token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-cluster","description":"Test cluster"}' \
  -k https://rancher.example.com/v3/clusters | jq '.'
```

**Delete token:**
```bash
curl -X DELETE \
  -H "Authorization: Bearer <api-token>" \
  -k https://rancher.example.com/v3/tokens/<token-id>
```

### API Endpoints Summary

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/v3-public/localProviders/local?action=login` | Authenticate (returns temp token) |
| POST | `/v3/tokens` | Create API token |
| GET | `/v3/tokens` | List all tokens |
| GET | `/v3/clusters` | List all clusters |
| POST | `/v3/clusters` | Create cluster |
| DELETE | `/v3/tokens/<id>` | Delete token |

