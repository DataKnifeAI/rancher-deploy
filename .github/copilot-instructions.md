# Copilot Instructions for Rancher Deploy Project

## Project Overview

This project deploys a complete Rancher management cluster and non-production apps cluster on Proxmox using Terraform. It demonstrates infrastructure-as-code best practices with automated VM provisioning, networking, and cluster orchestration.

- **Rancher Manager Cluster**: 3 nodes (VM 401-403), runs Rancher control plane
- **NPRD Apps Cluster**: 3 nodes (VM 404-406), non-production workloads
- **Network**: Unified VLAN 14 (192.168.1.x/24) for simplified management
- **Provider**: bpg/proxmox v0.90.0 (reliable, well-maintained)
- **Kubernetes**: RKE2 v1.34.3+rke2r1 (specific stable version - NOT "latest")

## Development Environment

### Recommended Shell Environment
- **Supported**: `bash` or `zsh` (both fully compatible with all scripts and automation)
- **Not recommended**: Fish shell
  - If you're using Fish shell, **consider switching to `zsh`** for better compatibility
  - Reason: Our scripts and automation tools are optimized for bash/zsh syntax
  - Zsh provides excellent compatibility with bash scripts while adding modern features
  - AI assistants work more effectively with bash/zsh based automation
  - To switch: `chsh -s /bin/zsh`

## Latest Updates (Jan 3, 2026)

### Native Rancher Cluster Registration (MAJOR - New Feature)

**Status**: ✅ **FULLY AUTOMATED** - Native rancher2 provider integration

**What Changed:**
- Implemented native `rancher2_cluster` resource for downstream cluster registration
- Rancher API token automatically created during deployment (no manual UI steps)
- Single `terraform apply` deploys everything end-to-end (VMs + RKE2 + Rancher + Apps Registration)
- **Zero manual copy/paste of registration tokens**
- **No Rancher UI steps required**

**How It Works:**
1. `deploy-rancher.sh` creates Rancher API token and saves to `~/.kube/.rancher-api-token`
2. `provider.tf` configures `rancher2` provider to read token from file
3. `terraform/main.tf` includes native `resource "rancher2_cluster"` for apps cluster
4. Native provider automatically extracts registration credentials
5. VMs use credentials to self-register with Rancher system-agent
6. Cluster becomes fully operational without manual intervention

**Files Changed:**
- `terraform/provider.tf` - Added rancher2 provider with file-based token reading
- `terraform/modules/rancher_cluster/deploy-rancher.sh` - Creates and persists API token
- `terraform/main.tf` - Added native rancher2_cluster resource
- `terraform/variables.tf` - Removed deprecated manual registration variables
- `terraform/terraform.tfvars` - Cleaned up deprecated variable assignments

**Key Benefits:**
- ✅ Fully automated (no UI steps)
- ✅ Single terraform apply (30-50 minutes total)
- ✅ Self-healing (token auto-refreshed)
- ✅ CI/CD friendly (no interactive steps)
- ✅ GitOps compatible (full state in Terraform)

**Deployment Time:**
- VM creation: 10-15 min
- RKE2 installation: 10-15 min
- Rancher deployment: 5-10 min
- **Downstream registration**: 2-3 min (NATIVE - automatic!)
- **Total: 30-50 minutes** (fully automated)

### Critical Fixes & Key Lessons

**1. Proxmox Cloud Image Import Path**
- When using `content_type = "import"`, Proxmox stores files in `import/` subdirectory
- Use: `import_from = "images-import:import/${var.cloud_image_file_name}"` (NOT without `import/`)
- Error if wrong: `unable to parse directory volume name`

**2. RKE2 Version Management**
- Always use specific version tags: `v1.34.3+rke2r1` (NOT "latest")
- "latest" is not a downloadable release
- Check available versions: https://github.com/rancher/rke2/tags

**3. RKE2 HA Port Configuration**
- **Port 9345**: Server registration (secondary nodes join primary)
- **Port 6443**: Kubernetes API (kubectl, only after cluster initialized)
- Configuration uses `RKE2_URL="https://<primary>:9345"` for joining

**4. Cloud-Init Initialization**
- VMs must complete cloud-init before RKE2 installation
- Use boot-finished file check (simpler than status polling)
- Prevents hanging on incomplete network initialization

**5. RKE2 Installation**
- Use config files (`/etc/rancher/rke2/config.yaml`), not environment variables
- Primary node initializes HA cluster, secondaries join via port 9345
- Set `RKE2_CLUSTER_INIT=true` only on primary for proper etcd clustering

**6. SSH Connection Management**
- Be aware of IPS/firewall blocks on high-frequency SSH during provisioning
- Solution: Whitelist Terraform runner IP in security policies
- Affects automation tools only, not core RKE2 functionality
```
1. VM created and boots (30-50 seconds)
2. SSH provisioner connects (attempts until available)
3. RKE2 installation script begins
4. Script waits for cloud-init completion (120 seconds max)
5. Script verifies network connectivity (30 seconds max)
6. Script verifies DNS resolution (30 seconds max)
7. RKE2 installer downloaded and executed (5-10 minutes)
8. Token file polling for cluster readiness (120 seconds max)
```

**Key Takeaway for Future Development:**
- Never assume SSH connectivity implies system readiness
- Always verify cloud-init completion explicitly
- Always test network connectivity before external downloads
- Use logging (tee -a) to track all provisioning steps
- Provide clear retry messages for debugging

### RKE2 Installer Download Fix - Write Error (Jan 2, 2026)

**Critical Discovery**: RKE2 installer download failing with curl exit code 23 (write error)

**Root Cause**: The cloud-init wrapper script copies itself to `/tmp/rke2-install.sh`, then tries to download the actual RKE2 installer to the same filename. When the script is running from that path, **the OS prevents overwriting the currently-executing file**, causing curl write errors.

**Symptoms**:
- Download appears to fail silently (all 5 retries fail identically)
- Direct curl testing from VM succeeds, but fails within the script
- HTTP response 200 (success) but curl exits with code 23 (write error)
- All 3 managers fail at same step with identical error pattern

**Solution Implemented**:
Changed installer download path from `/tmp/rke2-install.sh` to `/tmp/rke2-installer.sh`:
- Script wrapper stays at `/tmp/rke2-install.sh`
- Actual RKE2 installer downloads to `/tmp/rke2-installer.sh`
- No conflict between executing wrapper and downloaded binary
- Both execution paths (`"$INSTALLER"` lines) use correct variable

**Error Detection**:
Added error capture to script to expose curl exit codes:
```bash
CURL_OUTPUT=$(timeout 60 curl -sfL ... 2>&1)
CURL_EXIT=$?
if [ $CURL_EXIT -ne 0 ]; then
  log "  curl exit code: $CURL_EXIT, error: $CURL_OUTPUT"
fi
```

**Curl Exit Codes Reference**:
- Exit code 0: Success
- Exit code 23: Write/read error (prevented from writing to executing file)
- Exit code 28: Operation timeout
- Exit code 35: SSL/TLS error

**Files Changed**:
## Project Structure

### Documentation (`docs/`)
Core documentation for users and developers:
- `DEPLOYMENT_GUIDE.md` - Complete deployment guide with logging instructions
- `DNS_CONFIGURATION.md` - Complete DNS configuration guide (node-level DNS approach)
- `DNS_CONFIGURATION.md` - DNS records required for Rancher
- `TROUBLESHOOTING.md` - Common issues and solutions
- `CLOUD_IMAGE_SETUP.md` - Cloud image provisioning details

### Terraform Configuration (`terraform/`)
Infrastructure-as-code using Terraform:
- `main.tf` - Cluster module definitions
- `provider.tf` - bpg/proxmox provider configuration
- `variables.tf` - Input variable definitions
- `outputs.tf` - Output values for cluster access
- `terraform.tfvars.example` - Example variable values
- `modules/proxmox_vm/` - Reusable VM resource module
- `modules/rke2_manager_cluster/` - Manager cluster verification
- `modules/rke2_downstream_cluster/` - Apps cluster provisioning

### Scripts (Root)
- `apply.sh` - Deploy with automatic logging (recommended method)

## Key Guidelines

### Deployment

**RECOMMENDED: Use the apply.sh script**

```bash
cd /home/lee/git/rancher-deploy
./apply.sh
```

This automatically:
- Sets up debug logging (`TF_LOG=debug`)
- Saves logs to timestamped file: `terraform/terraform-<timestamp>.log`
- Runs terraform apply with auto-approval in background

**IMPORTANT**: The apply.sh script always starts terraform apply in the background. Do NOT run terraform apply again - just monitor the logs.

**Expected Deployment Timeline:**
- Ubuntu image download: 30-40 seconds
- VM creation: 1-2 minutes
- SSH connectivity: 3-5 minutes
- RKE2 installation: 5-10 minutes per cluster
- Token verification: 1-2 minutes
- **Total: 25-30 minutes**

**Monitoring:**
```bash
# Watch the logs in real-time
tail -f terraform/terraform-<timestamp>.log

# Filter for key events
grep -E "Creating|Complete|ERROR" terraform/terraform-<timestamp>.log
```

### Terraform Development

#### Variable Naming and Documentation
- Use snake_case for variable names
- Always include `description` field explaining purpose
- Use `type` to enforce data types (string, number, map, list, etc.)
- Mark sensitive values with `sensitive = true`
- Provide realistic defaults where appropriate

**Sensitive Variables:**
- `proxmox_api_token_secret`
- `ssh_private_key`
- Store in `terraform.tfvars` (never commit actual values)
- Use `terraform.tfvars.example` as template for users

#### Module Architecture
- **Single module pattern**: `proxmox_vm` module handles all VM creation
- **Cluster orchestration**: Pass cluster configuration via variables, not hard-coded values
- **Module reusability**: Both manager and apps clusters use same module with different parameters
- **Explicit dependencies**: Use `depends_on` to control deployment order (apps waits for manager)

#### Resource Naming
- **Provider resources**: `proxmox_virtual_environment_vm` (from bpg/proxmox)
- **Terraform variables**: snake_case (e.g., `proxmox_api_url`)
- **Terraform outputs**: snake_case (e.g., `rancher_manager_ip`)
- **Local values**: snake_case (e.g., `vm_tags`)

#### Network Configuration
- **VLAN**: 14 (unified segment)
- **Manager nodes**: 192.168.1.10x (100-102)
- **Apps nodes**: 192.168.1.11x (110-112)
- **Gateway**: 192.168.1.1
- **Cloud-init**: Handles static IP, DNS, hostname configuration

#### Cluster Orchestration Pattern
```hcl
module "rancher_manager" {
  source = "./modules/proxmox_vm"
  # ... configuration for 3-node manager cluster
}

module "nprd_apps" {
  source = "./modules/proxmox_vm"
  depends_on = [module.rancher_manager]  # Manager first
  # ... configuration for 3-node apps cluster
}
```

### Documentation Standards

#### README.md Structure
1. Project title and purpose
2. Features list
3. Architecture overview (brief)
4. Prerequisites section
5. Quick start (3-5 steps)
6. Documentation links (point to docs/ folder)
7. Project structure overview
8. Key features explanation
9. Usage and configuration
10. Troubleshooting basics with link to detailed guide
11. Support and resources

#### Guide Documents (in `docs/`)
Follow consistent structure:
1. **Title**: Clear indication of guide purpose
2. **Overview**: What will be accomplished
3. **Prerequisites**: Required tools, accounts, knowledge
4. **Step-by-step instructions**: Numbered, clear, testable
5. **Configuration examples**: Real code with explanations
6. **Verification**: How to confirm success
7. **Troubleshooting**: Issues specific to this guide
8. **Next steps**: Related guides or post-deployment tasks
9. **Related documentation**: Cross-references to other docs

#### Troubleshooting Guide Format
Organize by category (Terraform, Proxmox API, VMs, Networking, SSH, etc.):
```markdown
## Category Name

### Issue: [User-facing symptom]
**Error message**: [Actual error text if applicable]
**Solutions**:
1. [First approach with commands]
2. [Alternative approach]
3. [Debug/diagnostic approach]
```

#### Architecture Documentation
Include:
- System diagram/ASCII art
- Component descriptions
- Network topology
- Data flows
- Resource requirements
- Scalability considerations
- Disaster recovery approach

### Provider Information

#### Current: bpg/proxmox v0.90.0
**Advantages over other providers:**
- ✅ Reliable task polling with exponential backoff retry
- ✅ Better error handling and diagnostics
- ✅ Proper cloud-init integration
- ✅ Full Proxmox VE 8.x and 9.x support
- ✅ Improved API stability
- ✅ Active community development (1.7K+ GitHub stars, 130+ contributors)

**Resource Type**: `proxmox_virtual_environment_vm` for QEMU VMs

**Provider Configuration:**
```hcl
provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_user}!${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_tls_insecure
  
  ssh {
    agent    = true
    username = "root"
  }
}
```

### Best Practices

#### Infrastructure as Code Principles
1. **Idempotency**: Apply multiple times with same result
2. **State isolation**: Separate tfvars for different environments
3. **Modularity**: Reuse modules, avoid code duplication
4. **Documentation**: Every variable must be documented
5. **Version pinning**: Use specific versions (RKE2), not "latest"
5. **Version control**: Git for all code and examples

#### Cluster Deployment
1. **Sequence**: Manager cluster always first
2. **Dependencies**: Use `depends_on` for explicit ordering
3. **Configuration**: Cloud-init handles all post-boot setup
4. **Verification**: SSH access verifies successful deployment
5. **Timing**: Allow 2-3 minutes total for all 6 VMs

#### Network Configuration
- **VLAN tagging**: Applied at vmbr0 level in Proxmox
- **Static IPs**: Configured via cloud-init, not DHCP
- **Connectivity**: Test with ping before proceeding
- **DNS**: Configured per cluster, can be customized
- **Unified segment**: All VMs on same VLAN for simplicity

#### Debugging Techniques
```bash
# Terraform debugging
export TF_LOG=debug
terraform plan > debug.log 2>&1

# Provider debugging
export PROXMOX_LOG_LEVEL=debug
terraform apply

# Check Proxmox tasks
# Via UI: Datacenter → Tasks → View logs

# Monitor VM console
# Via UI: VMs → Select VM → Console → Monitor cloud-init

# Verify in VM
ssh ubuntu@192.168.1.100
cloud-init status
cloud-init query
ip addr show
```

### Code Quality Standards

#### Terraform Formatting
```bash
# Format all Terraform files
terraform fmt -recursive

# Validate configuration
terraform validate

# Check for unused variables
terraform console  # Then: keys(var.*)
```

#### Documentation Quality
- Clear, concise language (avoid jargon where possible)
- Code examples for all configuration options
- Cross-references between related topics
- Troubleshooting sections in major guides
- Consistent formatting and styling

#### Error Handling
- Meaningful error messages
- Provide solutions, not just problems
- Include command examples for debugging
- Link to relevant troubleshooting sections

## Common Development Tasks

### Adding a New Documentation File

1. **Create file in `docs/`**: Use descriptive name (e.g., `DEPLOYMENT_GUIDE.md`)
2. **Structure content**:
   - Header with clear title
   - Overview paragraph
   - Prerequisites section
   - Main content with examples
   - Troubleshooting for that topic
   - Links to related docs
3. **Cross-reference**:
   - Add link to README.md documentation section
   - Link from related documents
   - Include in .github/copilot-instructions.md

### Updating Terraform Configuration

1. **Format code**: `terraform fmt -recursive`
2. **Validate**: `terraform validate`
3. **Review**: Check variable descriptions are clear
4. **Test plan**: `terraform plan > plan.txt` (review changes)
5. **Manual test** (if applicable):
   - Plan on test environment
   - Apply changes
   - Verify VMs are created and configured
   - Destroy to clean up
6. **Commit**: Clear message describing changes

### Handling Issues and Troubleshooting

1. **Reproduce**: Run with debug logging enabled
   ```bash
   export TF_LOG=debug TF_LOG_PATH=terraform.log
   terraform apply -auto-approve
   ```

2. **Gather info**:
   - Terraform state: `terraform state list`
   - Terraform logs: Check `terraform/terraform-*.log`
   - Proxmox task history
   - VM console output
   - Cloud-init logs in VM

3. **Document solution**: Add to TROUBLESHOOTING.md if applicable
4. **Test fix**: Verify in test environment
5. **Commit**: Reference issue if applicable

### RKE2 Version Management

1. **Check available versions**: https://github.com/rancher/rke2/tags
2. **Always use specific versions**: `v1.34.3+rke2r1` NOT "latest"
3. **Update in two places**:
   - `terraform/main.tf` - Module calls for both clusters
   - `terraform/modules/rke2_cluster/main.tf` - Module default
4. **Clean state after version change**:
   ```bash
   rm -f terraform.tfstate*
   terraform apply -auto-approve
   ```

### Deploying with Logging

**RECOMMENDED: Use the apply.sh script**

```bash
# From project root directory
./apply.sh -auto-approve
```

This automatically:
- Sets up debug logging (`TF_LOG=debug`)
- Saves logs to timestamped file: `terraform/terraform-<timestamp>.log`
- Changes to terraform directory
- Runs terraform apply with auto-approval
- Monitors progress in background

**IMPORTANT**: The `apply.sh` script **always starts terraform apply in the background**. Do NOT run terraform apply again - just monitor the logs.

**Manual deployment with logging (if not using apply.sh):**

```bash
cd terraform
export TF_LOG=debug TF_LOG_PATH=terraform.log
terraform apply -auto-approve
```

**Log levels (TF_LOG environment variable):**
- `trace` - Most verbose (includes all API calls)
- `debug` - Detailed operation info (recommended)
- `info` - Normal output (least verbose)
- `warn` / `error` - Only warnings and errors

**Deployment timeline expectations:**
1. **Cloud image download**: 30-40 seconds
2. **VM creation**: 1-2 minutes
3. **SSH connection attempts**: 3-5 minutes (VMs booting, SSH becoming available)
4. **RKE2 installation**: 5-10 minutes per cluster
5. **Token verification**: 1-2 minutes
6. **Total deployment time**: 25-30 minutes from apply.sh start

**Monitoring deployment progress:**

```bash
# Check if deployment is running
ps aux | grep terraform | grep -v grep

# Watch the logs in real-time
tail -f terraform/terraform-<timestamp>.log

# Filter for key events
grep -E "Creating|Complete|ERROR" terraform/terraform-<timestamp>.log
```

## Testing Recommendations

### Before Pushing Changes

1. **Syntax and formatting**:
   ```bash
   terraform fmt -recursive
   terraform validate
   ```

2. **Documentation review**:
   - Check all examples are correct
   - Verify cross-references work
   - Test commands shown in docs

3. **Code review**:
   - Variables are documented
   - No hardcoded values
   - Proper error handling

4. **Manual testing** (in test environment):
   ```bash
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   # Verify outputs and VM access
   terraform destroy
   ```

### Full Integration Test Procedure

```bash
# 1. Clean state
cd /path/to/rancher-deploy/terraform
rm -rf .terraform .terraform.lock.hcl
rm -f tfplan

# 2. Fresh init and plan
terraform init
terraform plan -out=tfplan
# Review plan carefully

# 3. Apply and verify
terraform apply tfplan
terraform output
# Check IPs and test SSH access

# 4. Cleanup
terraform destroy
```

## Quick Reference

### Essential Files
| File | Purpose |
|------|---------|
| `README.md` | Project overview and quick-start |
| `terraform/main.tf` | Cluster definitions |
| `terraform/provider.tf` | Provider configuration |
| `docs/GETTING_STARTED.md` | User setup guide |
| `docs/TERRAFORM_GUIDE.md` | Detailed deployment |
| `docs/TROUBLESHOOTING.md` | Issue resolution |

### Important Commands
```bash
# Terraform core
terraform init              # Initialize Terraform
terraform validate          # Validate configuration
terraform fmt -recursive    # Format code
terraform plan             # Preview changes
terraform apply            # Apply changes
terraform destroy          # Remove infrastructure

# Debugging
export TF_LOG=debug        # Enable Terraform debug
export PROXMOX_LOG_LEVEL=debug  # Enable provider debug

# State inspection
terraform state list       # List resources
terraform state show <resource>  # Show resource details
```

### Useful Variables
- `proxmox_api_url`: Proxmox API endpoint
- `proxmox_api_user`: API user (e.g., terraform@pam)
- `proxmox_api_token_id`: Token ID from API token
- `proxmox_api_token_secret`: Token secret (sensitive)
- `vm_template_id`: Ubuntu template VM ID (default: 400)
- `ssh_private_key`: Path to SSH key for VM access

## Documentation Maps

### For Users
1. Start: [README.md](../README.md)
2. DNS Setup: [DNS_CONFIGURATION.md](../docs/DNS_CONFIGURATION.md)
3. DNS Records: [DNS_CONFIGURATION.md](../docs/DNS_CONFIGURATION.md)
4. Deploy: [DEPLOYMENT_GUIDE.md](../docs/DEPLOYMENT_GUIDE.md)
5. Cloud Images: [CLOUD_IMAGE_SETUP.md](../docs/CLOUD_IMAGE_SETUP.md)
6. Understand: [MODULES_AND_AUTOMATION.md](../docs/MODULES_AND_AUTOMATION.md)
7. Troubleshoot: [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md)

### For Developers
1. Review: [MODULES_AND_AUTOMATION.md](../docs/MODULES_AND_AUTOMATION.md)
2. DNS Architecture: [DNS_CONFIGURATION.md](../docs/DNS_CONFIGURATION.md)
3. Cloud Images: [CLOUD_IMAGE_SETUP.md](../docs/CLOUD_IMAGE_SETUP.md)
4. Deploy: [DEPLOYMENT_GUIDE.md](../docs/DEPLOYMENT_GUIDE.md)
5. Debug: [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md)
6. Reference: This file (.github/copilot-instructions.md)

## Support and Resources

### External Documentation
- **Proxmox**: https://pve.proxmox.com/wiki/Main_Page
- **Terraform**: https://www.terraform.io/docs/
- **Rancher**: https://rancher.com/docs/
- **Provider**: https://github.com/surrealwolf/terraform-pve

### Internal Documentation
- Project README: [../README.md](../README.md)
- Deployment: [../docs/DEPLOYMENT_GUIDE.md](../docs/DEPLOYMENT_GUIDE.md)
- All guides: [../docs/](../docs/)
- **Gotchas**: TLS validation can be disabled via `proxmox_tls_insecure` (for lab/dev only)

### RKE2 Kubernetes
- **Installation**: Manual per-node via `curl ... | sh -` (NOT automated by Terraform; docs assume SSH post-deploy)
- **First node**: Becomes RKE2 server; generates token for agent joins
- **Token sharing**: Agents need server token—documented in `QUICKSTART.md`, must be retrieved manually from server node
- **Kubeconfig**: Retrieved post-deployment via `configure-kubeconfig.sh` which SCPs from `/etc/rancher/rke2/rke2.yaml`

### Rancher + cert-manager
- Not yet provisioned by Terraform (Helm providers defined but unused in current implementation)
- **TODO**: `terraform/modules/rancher_cluster/main.tf` exists but is not called; should deploy Rancher Server on manager via Helm

## Testing & Validation

### Pre-Deployment Checks
- `terraform validate`: Checks syntax (run via `make validate-manager` and `make validate-nprd`)
- `terraform plan -out=tfplan`: Shows changes; artifact is committed for `apply` (not re-planned interactively)

### Post-Deployment Verification
1. VMs exist in Proxmox UI with correct IPs and hostnames
2. SSH to each node: `ssh ubuntu@192.168.1.100` (and .101, .102, then 192.168.2.x nodes)
3. After RKE2 install: `kubectl get nodes` from kubeconfig should list 3 nodes per cluster
4. Rancher manager accessible at `https://rancher_hostname` (bootstrapped with `rancher_password`)

## Common Mistakes to Avoid

1. **Mixing environments**: Don't run `terraform apply` from root; always CD into `terraform/environments/{manager,nprd-apps}`
2. **State pollution**: Each environment has separate `backend.tf` and S3/local state; destroying one doesn't affect the other
3. **Forgotten `.tfvars`**: Copy `.example` and edit BEFORE `terraform init`; missing variables will error at init time
4. **Template ID mismatch**: Proxmox template ID must exist and have Cloud-Init; verify in Proxmox UI before deploy
5. **SSH key permissions**: `ssh_private_key` path in vars must be readable; use absolute paths
6. **IP conflicts**: Manager and nprd-apps use separate subnets (192.168.1.x vs 192.168.2.x) to avoid overlap; if modifying, ensure no collisions
