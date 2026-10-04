# Proxmox API Token Creation and Permissions Guide

This guide covers creating and configuring Proxmox API tokens with the minimum required permissions for the Rancher Deploy automation to work end-to-end.

> This page is about the **Proxmox** token only. For the Rancher API token Terraform uses, see [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md); for kubectl / Rancher login (SSO), see [CLUSTER_ACCESS_AND_SSO.md](CLUSTER_ACCESS_AND_SSO.md).

## Overview

The Rancher Deploy project uses Proxmox API tokens to automate infrastructure provisioning. You'll need to create at least one API token with specific permissions for VM creation, configuration, and management.

## Required Permissions

### Minimum Permissions Required

For the deployment to work end-to-end, your API token needs these permissions:

| Permission | Purpose | Required |
|---|---|---|
| `Datastore.Allocate` | Create and modify datastores | ✅ Yes |
| `Datastore.Browse` | Access datastore contents | ✅ Yes |
| `Nodes.Shutdown` | Reboot/shutdown nodes | ✅ Yes |
| `Qemu.Allocate` | Create and modify VMs | ✅ Yes |
| `Qemu.Clone` | Clone VMs from templates | ✅ Yes |
| `Qemu.Console` | Access VM console | ✅ Yes |
| `Qemu.Config.Memory` | Configure VM memory | ✅ Yes |
| `Qemu.Config.Network` | Configure VM networking | ✅ Yes |
| `Qemu.Config.Disk` | Configure VM disks | ✅ Yes |
| `Qemu.Migrate` | Migrate VMs between nodes | ✅ Yes |
| `Qemu.Monitor` | Monitor VM performance | ✅ Yes |
| `Qemu.PowerMgmt` | Start, stop, reboot VMs | ✅ Yes |
| `Qemu.Snapshot` | Create VM snapshots | ⚠️ Optional |
| `Qemu.Backup` | Backup VMs | ⚠️ Optional |

## Creating the API Token in Proxmox

### Step 1: Access Proxmox Web Interface

1. Open your Proxmox VE web interface: `https://<proxmox-ip>:8006`
2. Login with your administrator account (typically `root@pam`)

### Step 2: Create API Token

Navigate to **Datacenter** → **Permissions** → **API Tokens**

Or access directly:
- **Path**: Datacenter → Users → Select User → API Tokens

**For standard deployments**, create token for `root@pam` user (admin account)

### Step 3: Generate New Token

Click **Add** button and fill in:

| Field | Value | Example |
|---|---|---|
| **Token ID** | Name for the token | `terraform` |
| **Expire** | Token expiration (optional) | Never (leave blank) |
| **Privilege Separation** | Whether to separate privileges | Unchecked (for full permissions) |

Click **Add** to generate the token.

### Step 4: Record Token Secret

⚠️ **IMPORTANT**: The token secret is only displayed once. Copy it immediately:

- **Format**: `<token-id>=<secret>`
- **Example**: `terraform=a1b2c3d4-e5f6-7890-abcd-ef1234567890`

Store securely (password manager, secure vault, etc.)

### Step 5: Add Permissions to Token

The token inherits permissions from the user. For `root@pam`, it automatically has all permissions. For security-conscious deployments, create a dedicated user:

#### Option A: Use Existing root@pam User (Simple)

```
Token user: root@pam (already has all permissions)
No additional permission assignment needed
```

#### Option B: Create Dedicated User (Recommended for Production)

1. Go to **Datacenter** → **Users** → **Add**
2. Create new user: `terraform@pam`
3. Set password
4. Go to **Permissions** tab → **Add**
5. Assign path `/` with role `Administrator`
6. Then create API token for this new user

## Terraform Configuration

### Update terraform.tfvars

After creating the API token, update your `terraform/terraform.tfvars`:

```hcl
# Proxmox API endpoint
proxmox_api_url = "https://<proxmox-ip>:8006/api2/json"

# API user (typically root@pam)
proxmox_api_user = "root@pam"

# Token ID from step 3 above
proxmox_api_token_id = "terraform"

# Token secret from step 4 above
proxmox_api_token_secret = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

# Proxmox node name
proxmox_node = "pve"

# TLS verification (set to false for self-signed certs in lab/dev)
proxmox_tls_insecure = true  # Change to false in production
```

### Security Best Practices

1. **Keep token secret secure**:
   - Store in password manager
   - Never commit `terraform.tfvars` to git (use `.gitignore`)
   - Use `terraform.tfvars.example` as template for team sharing

2. **Token expiration**:
   - Consider setting expiration date for automatic rotation
   - Renew periodically (monthly/quarterly)

3. **Dedicated user (production)**:
   - Create `terraform@pam` user instead of using `root@pam`
   - Limit to required permissions only (principle of least privilege)

4. **Audit tokens**:
   - Regularly review tokens: **Datacenter** → **Permissions** → **API Tokens**
   - Remove unused/old tokens
   - Check token creation dates and expiration

## Verifying Token Permissions

### Test Token with curl

```bash
# Test API connectivity and permissions
TOKEN_ID="terraform"
TOKEN_SECRET="your-token-secret"
PROXMOX_URL="https://your-proxmox:8006"

curl -X GET \
  -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
  -k "${PROXMOX_URL}/api2/json/nodes"
```

Expected response: List of Proxmox nodes (JSON array)

### Test in Terraform

```bash
cd terraform
terraform init
terraform plan
```

If token is valid, plan will show proposed resources.

If token lacks permissions, you'll see errors like:
```
Error: Insufficient permissions for user 'root@pam@pam'
```

## Troubleshooting Token Issues

### Issue: "401 Unauthorized" or "Authentication Failed"

**Causes & Solutions:**

1. **Token doesn't exist or is malformed**
   - Verify token ID and secret are correct
   - Check for typos or extra spaces
   - Ensure secret matches the token generated in Proxmox

2. **Token has expired**
   - Check expiration date in Proxmox UI
   - Create new token if expired
   - Set no expiration (leave blank) for long-term tokens

3. **User or token was deleted**
   - Check Proxmox → Datacenter → Users
   - Check Proxmox → Datacenter → API Tokens
   - Recreate if missing

**Verification Steps:**

```bash
# 1. Double-check your token values
grep "proxmox_api_token" terraform/terraform.tfvars

# 2. Verify in Proxmox UI
# Datacenter → Permissions → API Tokens
# Look for your token ID and verify it exists

# 3. Test with curl (substitute your values)
TOKEN_ID="terraform"
TOKEN_SECRET="your-secret-value"
PROXMOX_URL="https://your-proxmox:8006"

curl -X GET \
  -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
  -k "${PROXMOX_URL}/api2/json/version"

# Should return Proxmox version information
```

### Issue: "Insufficient Permissions" or "403 Forbidden"

**Cause**: Token user doesn't have required permissions

**Solutions:**

1. **For root@pam user**:
   - Should already have all permissions
   - Check token wasn't created with privilege separation
   - Verify in Proxmox → Datacenter → Users → root@pam

2. **For dedicated user**:
   - Go to Proxmox → Datacenter → Permissions
   - Check user has "Administrator" or equivalent role
   - Add permissions if missing:
     - Path: `/`
     - User/Token: `terraform@pam` or equivalent
     - Role: `Administrator`

3. **Verify minimum permissions**:
   ```bash
   # Check what role/permissions are assigned
   curl -X GET \
     -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
     -k "${PROXMOX_URL}/api2/json/access/acl"
   ```

## Token Security in Terraform

### Secure Token Management

**Option 1: Environment Variables** (Recommended for CI/CD)

```bash
export PROXMOX_VE_ENDPOINT="https://your-proxmox:8006"
export PROXMOX_VE_API_TOKEN="${TOKEN_ID}=${TOKEN_SECRET}"
terraform apply
```

**Option 2: terraform.tfvars** (Development)

```hcl
# terraform/terraform.tfvars (add to .gitignore!)
proxmox_api_url          = "https://your-proxmox:8006/api2/json"
proxmox_api_user         = "root@pam"
proxmox_api_token_id     = "terraform"
proxmox_api_token_secret = "your-secret-token"
```

**Option 3: Terraform Cloud/Enterprise**

1. Store token in Terraform Cloud variables (sensitive)
2. Reference in configuration
3. No local token storage needed

### Protecting Your Token

```bash
# Ensure terraform.tfvars is not tracked by git
echo "terraform/terraform.tfvars" >> .gitignore

# Check no tokens are in git history
git log -p --all -S "api_token_secret" | head -20

# If accidentally committed, rotate the token immediately
# 1. Generate new token in Proxmox UI
# 2. Delete old token in Proxmox UI
# 3. Update terraform.tfvars with new token
# 4. Force-push to remove from history (if in private repo)
```

## Multi-User/Multi-Environment Setup

### Creating Environment-Specific Tokens

For organizations with multiple environments (dev, staging, prod):

**Dev Environment Token**:
```
User: terraform-dev@pam
Token ID: terraform-dev
Permissions: All nodes in dev cluster
```

**Production Environment Token**:
```
User: terraform-prod@pam
Token ID: terraform-prod
Permissions: Only prod cluster nodes (restricted)
```

**Example Terraform Configuration**:

```bash
# Use different tfvars for each environment
terraform apply -var-file="environments/dev.tfvars"
terraform apply -var-file="environments/prod.tfvars"
```

### Token Rotation Schedule

For security best practices:

- **Development**: No expiration (lab environment)
- **Staging**: Rotate every 6 months
- **Production**: Rotate every 3 months

**Rotation Process**:
1. Create new token in Proxmox
2. Update terraform configuration with new token
3. Test new token: `terraform plan`
4. After confirmation, delete old token in Proxmox UI

## Permissions Reference

### Complete Permissions List

Full list of available Proxmox permissions:

| Category | Permissions |
|---|---|
| **Datastore** | Allocate, Browse, Delete |
| **Nodes** | Audit, PowerMgmt, Shutdown |
| **Qemu (VMs)** | Allocate, Backup, Clone, Config.*, Console, Migrate, Monitor, PowerMgmt, Snapshot |
| **LXC (Containers)** | Allocate, Backup, Clone, Config.*, Console, Migrate, Snapshot |
| **Storage** | Allocate, Audit, Browse, Delete |
| **Permissions** | Allocate, Modify |
| **Access** | CheckPassword, Modify |

### For This Project

**Minimum required** (as listed in table above):
- `Datastore.*` (Allocate, Browse)
- `Nodes.*` (Shutdown)
- `Qemu.*` (most Qemu permissions)

**Optional but recommended**:
- `Qemu.Snapshot` - For backup snapshots
- `Qemu.Backup` - For VM backups

## Common Issues and Solutions

### Token Created But Terraform Still Fails

1. **Restart any caching services**:
   ```bash
   # If using local Proxmox
   sudo systemctl restart pveproxy
   ```

2. **Clear Terraform cache**:
   ```bash
   rm -rf terraform/.terraform
   terraform init
   ```

3. **Verify token exists**:
   ```bash
   curl -X GET \
     -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}" \
     -k "${PROXMOX_URL}/api2/json/access/ticket
   ```

### "User does not exist" Error

**Cause**: User account (e.g., `root@pam`) doesn't exist

**Solution**:
- Verify correct Proxmox realm (typically `pam` for local auth)
- Check user exists: Datacenter → Users
- Common realms: `pam` (local), `pve` (built-in), LDAP realms

### Multiple Tokens for Same User

**Common scenario**: Different teams/projects needing separate tokens

**Solution**:
1. Create multiple tokens under same user (e.g., `root@pam`)
2. Track token IDs for different purposes:
   - `terraform` - Main Rancher deployment
   - `terraform-backups` - Backup automation
   - `monitoring` - Prometheus monitoring

## Next Steps

1. **Create your API token** - Follow steps 1-5 above
2. **Update terraform.tfvars** - Add token details
3. **Test token connectivity** - Run `terraform plan`
4. **Deploy infrastructure** - Run `./scripts/apply.sh`

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [`terraform/terraform.tfvars.example`](../terraform/terraform.tfvars.example) / [`terraform/variables.tf`](../terraform/variables.tf) - Variable reference
- [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md) - Rancher API token (not Proxmox)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Deployment troubleshooting

## Proxmox Documentation

- [Proxmox API Tokens](https://pve.proxmox.com/pve-docs/api-viewer/)
- [Proxmox Permissions](https://pve.proxmox.com/wiki/User_Management)
- [Proxmox Authentication](https://pve.proxmox.com/wiki/Authentication_-_Introduction)
