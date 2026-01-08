# Troubleshooting Guide

Common issues and solutions when deploying Rancher clusters on Proxmox.

## Terraform Issues

### Issue: "terraform init" fails with provider error

**Error:**
```
Error: Failed to query available provider packages...
```

**Solution:**
1. Verify internet connectivity
2. Ensure Terraform version >= 1.0
3. Clear cache: `rm -rf .terraform`
4. Retry `terraform init`

### Issue: Terraform plan shows no changes but nothing deployed

**Symptom:** `terraform plan` succeeds but `terraform apply` does nothing

**Solution:**
1. Check you're using correct state file: `terraform state list`
2. Verify variables are correctly set: `terraform plan -var-file=terraform.tfvars`
3. If needed, import existing resources: `terraform import pve_qemu.vm <vmid>`

## Proxmox API Issues

### Issue: "API authentication failed" or "403 Forbidden"

**Error:**
```
Error: ... 403 Forbidden
```

**Solutions:**

1. **Verify API token exists:**
   ```bash
   # In Proxmox UI:
   Datacenter → Users → Select user → API Tokens
   ```

2. **Check token permissions:**
   - Ensure token has permissions for:
     - Datastore.Allocate
     - Datastore.Browse
     - Nodes.Shutdown
     - VMs.Allocate
     - VMs.Clone
     - VMs.Console
     - VMs.Config.*

3. **Validate credentials in terraform.tfvars:**
   ```hcl
   proxmox_api_url          = "https://your-proxmox:8006/api2/json"
   proxmox_api_user         = "terraform@pam"
   proxmox_api_token_id     = "your-token-id"
   proxmox_api_token_secret = "your-token-secret"
   ```

4. **Test manually:**
   ```bash
   curl -X GET \
     -H "Authorization: PVEAPIToken=terraform@pam:your-token-id=your-token-secret" \
     https://your-proxmox:8006/api2/json/nodes
   ```

### Issue: "TLS certificate verification failed"

**Error:**
```
Error: ... x509: certificate signed by unknown authority
```

**Solutions:**

**Option 1: Fix certificate (recommended)**
1. Install valid certificate in Proxmox
2. Run Terraform: `terraform apply`

**Option 2: Disable verification (testing only)**
```hcl
# In terraform/variables.tf
variable "proxmox_tls_insecure" {
  default = true  # NOT for production!
}
```

## VM Creation Issues

### Issue: VM creation times out after 2+ minutes

**Symptom:** Terraform times out waiting for VM to be ready

**Solutions:**

1. **Enable debug logging:**
   ```bash
   export PROXMOX_LOG_LEVEL=debug
   terraform apply
   ```

2. **Check Proxmox task history:**
   ```bash
   # In Proxmox UI: Datacenter → Tasks
   # Look for failed clone or config tasks
   ```

3. **Verify VM template exists:**
   ```bash
   # Check template ID matches configuration
   # Proxmox UI: Datacenter → VMs → Look for VM 400 (or your template)
   ```

4. **Check storage space:**
   ```bash
   # Ensure local-vm-zfs has sufficient free space
   # Need: 6 VMs × 20GB = 120GB minimum
   ```

5. **Verify template is properly configured:**
   - Cloud-init drive present
   - Network interface configured
   - SSH public key loaded

### Issue: "VM already exists" error

**Error:**
```
Error: VM already exists
```

**Solutions:**

1. **Check if VM already created:**
   ```bash
   # Proxmox UI: Look for VMs 401-406
   ```

2. **Option A: Delete VMs and retry**
   ```bash
   # In Proxmox UI: Delete VMs 401-406
   terraform apply
   ```

3. **Option B: Import existing VMs**
   ```bash
   # Import VM 401:
   terraform import pve_qemu.vm["rancher-manager-1"] 401
   # Repeat for other VMs 402-406
   ```

### Issue: VMs created but cloud-init not applied

**Symptom:** VMs created but network not configured, can't SSH

**Solutions:**

1. **Check cloud-init status:**
   ```bash
   # SSH to VM (from Proxmox console):
   ssh ubuntu@<vm-console>
   cloud-init status
   cloud-init query
   ```

2. **Check cloud-init logs:**
   ```bash
   # In VM console:
   journalctl -u cloud-init -n 50
   ```

3. **Verify cloud-init data passed:**
   ```bash
   # In VM:
   ls -la /var/lib/cloud/instance/
   ```

4. **Check network configuration:**
   ```bash
   # In VM:
   ip addr show
   netplan status
   ```

## Network Issues

### Issue: VMs can't reach network or no IP address

**Symptom:** VM created but "ip addr show" shows no IPv4

**Solutions:**

1. **Verify VLAN configuration:**
   - Check vmbr0 has VLAN 14 support: `ip link show vmbr0`
   - Ensure vmbr0 configured properly in /etc/network/interfaces

2. **Check cloud-init network config:**
   ```bash
   # In VM:
   cat /etc/netplan/01-netcfg.yaml
   sudo netplan apply
   ip addr show
   ```

3. **Verify DNS resolution:**
   ```bash
   # In VM:
   cat /etc/resolv.conf
   # Should show DNS servers (not 127.0.0.53)
   # Example:
   # nameserver 192.168.1.1
   # nameserver 1.1.1.1
   
   nslookup example.com
   # Should resolve successfully
   ```

4. **Test gateway reachability:**
   ```bash
   # In VM:
   ping 192.168.1.1
   ```

### Issue: VMs on different clusters can't communicate

**Symptom:** Ping between manager and apps cluster fails

**Solution:**
1. Ensure both use same VLAN 14
2. Check firewall rules (Proxmox or upstream)
3. Verify routing between network segments

## SSH/Connection Issues

### Issue: "Permission denied (publickey)"

**Error:**
```
Permission denied (publickey).
```

**Solutions:**

1. **Verify SSH key path:**
   ```bash
   ls -la ~/.ssh/id_rsa
   ```

2. **Check key in Terraform config:**
   ```bash
   # In terraform.tfvars:
   ssh_private_key = "~/.ssh/id_rsa"  # Correct path?
   ```

3. **Verify public key in VM:**
   ```bash
   # Via Proxmox console:
   cat ~/.ssh/authorized_keys
   # Should contain your public key
   ```

4. **Check SSH permissions:**
   ```bash
   # In VM:
   ls -la ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   chmod 700 ~/.ssh
   ```

5. **Try with verbose output:**
   ```bash
   ssh -v -i ~/.ssh/id_rsa ubuntu@192.168.1.100
   ```

### Issue: Timeout connecting to SSH

**Error:**
```
Connection refused or timeout
Disconnected from 192.168.1.x port 22
```

**Common Causes:**

1. **Intrusion Prevention System (IPS) blocking SSH during provisioning**
   
   **Symptom**: SSH works initially (script uploads successfully) but connections timeout during active provisioning (package updates, RKE2 installation)
   
   **Root Cause**: IPS systems often block repeated SSH connections from automation tools during heavy activity, treating it as potential attack pattern
   
   **Solution**:
   - Contact network team to whitelist Terraform runner IP address
   - Increase SSH connection thresholds in IPS/firewall rules
   - Disable IPS temporarily on test networks during deployment
   - Configure IPS to allow high-frequency SSH from known automation IPs
   
   **How to Verify**:
   ```bash
   # Check if connections drop after successful script upload:
   # 1. Script uploads OK (SCP succeeds)
   # 2. SSH reconnect hangs for 5+ minutes
   # 3. Eventually either: times out or connects
   # This pattern = IPS issue
   
   # Check firewall logs on network perimeter
   # Look for: "Connection dropped", "Rate limit exceeded", "Threat detected"
   ```

2. **VM not fully booted**
   - Cloud-init may take 1-2 minutes  
   - Check in Proxmox console if services running
   - Verify cloud-init status: `cloud-init status`

3. **Network connectivity issues**
   ```bash
   ping 192.168.1.100  # From Proxmox host
   ```

4. **SSH service not running**
   ```bash
   # Via Proxmox console:
   sudo systemctl status ssh
   sudo journalctl -u ssh -n 50
   ```

**Solutions:**

**Option 1: Fix IPS (Recommended)**
1. Identify the IPS/firewall blocking connections
2. Whitelist Terraform runner IP address
3. Or disable/bypass IPS for test environments during deployment
4. Retry deployment

**Option 2: Increase Terraform timeouts (Workaround)**
```hcl
# In modules/proxmox_vm/main.tf
provisioner "remote-exec" {
  inline = ["echo 'VM ready'"]  
  connection {
    timeout = "10m"  # Increase from default 5m
    type    = "ssh"
    agent   = false
  }
}
```

**Option 3: Stagger provisioners (Workaround)**
```bash
# Reduce parallel provisioning to avoid triggering IPS rate limits
terraform apply -parallelism=1
```

**Option 4: Verify VM boot completion**
```bash
# SSH to a successfully provisioned VM
ssh ubuntu@192.168.1.100
cloud-init status --wait
cloud-init query
```

## Kubernetes/Rancher Issues

### Issue: RKE2 installation fails with "latest" version

**Error:**
```
curl: (22) The requested URL returned error: 404
Failed to enable unit: Unit file rke2-server.service does not exist
```

**Root Cause:**
The RKE2 installer cannot download a release called "latest". Only specific version tags (e.g., v1.34.3+rke2r1) are available as downloadable releases.

**Solutions:**

1. **Verify using actual release version:**
   ```hcl
   # In terraform/main.tf, use specific version:
   rke2_version = "v1.34.3+rke2r1"  # CORRECT - actual released version
   rke2_version = "latest"          # WRONG - not a downloadable release
   ```

2. **Check available versions:**
   ```bash
   # Visit GitHub releases page
   curl -s https://api.github.com/repos/rancher/rke2/releases?per_page=10 | jq '.[].tag_name'
   # Or browse: https://github.com/rancher/rke2/tags
   ```

3. **Latest stable version examples:**
   - v1.35.0+rke2r1 (latest)
   - v1.34.3+rke2r1 (stable)
   - v1.33.7+rke2r1 (supported)
   - v1.32.11+rke2r1 (supported)

4. **Update terraform.tfvars if needed:**
   ```hcl
   # terraform/terraform.tfvars
   rke2_version = "v1.34.3+rke2r1"
   ```

5. **Clean state and redeploy:**
   ```bash
   cd terraform
   rm -f terraform.tfstate*
   terraform apply -auto-approve
   ```

**Prevention:**
Always use specific version tags. Check GitHub releases before setting `rke2_version` variable.

### Issue: RKE2 installation script download fails

**Error:**
```
curl: (7) Failed to connect to get.rke2.io port 443: Connection refused
curl: (23) Failed writing body (0 != 1024) [write error]
```

**Root Causes & Solutions:**

**1. Curl Write Error (Exit Code 23) - File Write Conflict**

**Symptom**: Direct curl works, but fails within the RKE2 provisioning script
```
[2026-01-02 20:01:28]   curl exit code: 23, error: 
```

**Root Cause**: The wrapper script writes itself to `/tmp/rke2-install.sh`, then tries to download the actual RKE2 installer to the same filename. When the script is executing from that path, the OS prevents overwriting the currently-running file.

**Solution**: Use a different filename for the downloaded installer
```bash
# WRONG (will fail):
INSTALLER="/tmp/rke2-install.sh"  # Same as the wrapper script
timeout 60 curl -sfL https://get.rke2.io -o "$INSTALLER"

# CORRECT (will succeed):
INSTALLER="/tmp/rke2-installer.sh"  # Different from wrapper
timeout 60 curl -sfL https://get.rke2.io -o "$INSTALLER"
```

**How to Verify**:
```bash
# SSH to failed VM
ssh ubuntu@192.168.1.100

# Check if curl works outside the script
curl -sfL https://get.rke2.io -o /tmp/test.sh && echo "Direct curl works"

# Check curl exit code in script context
timeout 60 sudo -E bash /tmp/rke2-install.sh 2>&1 | grep "curl exit code"
```

**Files Affected**: `terraform/modules/proxmox_vm/cloud-init-rke2.sh` (fixed in latest version)

**2. Connection Refused - Network/Firewall Issue**

**Symptom**:
```
curl: (7) Failed to connect to get.rke2.io port 443: Connection refused
```

**Solutions:**

1. **Check internet connectivity:**
   ```bash
   ping github.com
   curl -I https://get.rke2.io
   ```

2. **Verify GitHub is accessible:**
   ```bash
   # RKE2 uses get.rke2.io which redirects to GitHub releases
   curl -L https://get.rke2.io | head -20
   ```

3. **Check firewall rules:**
   - Proxmox host must allow outbound HTTPS to github.com
   - VMs must allow outbound HTTPS to github.com
   - Test from VM: `curl https://api.github.com`

4. **Retry with increased timeout:**
   ```bash
   # Wait longer for provisioners
   export TF_PLUGIN_LOG=trace
   terraform apply
   ```

### Issue: RKE2 server doesn't start after installation

**Symptom:** Installation script completes but `systemctl status rke2-server` shows failed


**Solutions:**

1. **Check SSH into VM and verify installation:**
   ```bash
   ssh -i ~/.ssh/id_rsa ubuntu@192.168.1.100
   sudo systemctl status rke2-server
   sudo journalctl -u rke2-server -n 50
   ```

2. **Verify cloud-init completed:**
   ```bash
   cloud-init status
   cloud-init query
   ```

3. **Check system resources:**
   ```bash
   free -h          # RAM available
   df -h /          # Disk space
   nproc             # CPU cores
   ```

4. **Verify RKE2 binary installed:**
   ```bash
   ls -la /usr/local/bin/rke2
   which rke2
   ```

5. **Check logs:**
   ```bash
   sudo journalctl -u rke2-server --follow
   tail -100 /var/lib/rancher/rke2/agent/logs/kubelet.log
   ```

### Issue: RKE2 token file never appears

**Symptom:** `wait_for_rke2` provisioner times out after 120 attempts (~4 minutes)

**Solutions:**

1. **SSH to manager-1 and check RKE2 status:**
   ```bash
   ssh -i ~/.ssh/id_rsa ubuntu@192.168.1.100
   sudo systemctl status rke2-server
   sudo systemctl start rke2-server  # if not running
   ```

2. **Wait for RKE2 to fully start:**
   ```bash
   # RKE2 may take 2-3 minutes to fully initialize
   watch -n 5 'sudo ls -la /var/lib/rancher/rke2/server/node-token 2>/dev/null || echo "Token not ready"'
   ```

3. **Check installation succeeded:**
   ```bash
   sudo journalctl -u rke2-server -n 50 | grep -E "INFO|ERROR|WARN"
   ```

4. **Verify kubeconfig exists:**
   ```bash
   sudo ls -la /etc/rancher/rke2/rke2.yaml
   ```

## Kubernetes/Rancher Issues

### Issue: RKE2 cluster is not operational

### Issue: Kubernetes cluster not coming up

**Solutions:**

1. **Check VM resources:**
   - Ensure 4 cores, 8GB RAM minimum per node
   - Check `free -h` and `nproc` in VMs

2. **Verify network:**
   - All 3 nodes must reach each other
   - Test: `ping <other-node-ip>`

3. **Check kubelet status:**
   ```bash
   # In VM:
   sudo systemctl status kubelet
   journalctl -u kubelet -n 50
   ```

4. **For Rancher installation:**
   - Install helm on Rancher manager cluster
   - Install Rancher chart: `helm repo add rancher-stable ...`
   - See Rancher documentation for full setup

## Performance Issues

### Issue: VMs deploying very slowly (> 5 minutes per VM)

**Solutions:**

1. **Check Proxmox CPU/RAM:**
   - `top` or `htop` on Proxmox host
   - Reduce parallelism if overloaded

2. **Check storage performance:**
   - `iostat -x 1` on Proxmox host
   - May indicate slow disk or ZFS issues

3. **Reduce parallelism:**
   ```bash
   terraform apply -parallelism=2
   ```

### Issue: High memory/CPU usage on Proxmox host

**Solutions:**

1. **Reduce VM resource allocation:**
   ```hcl
   variable "vm_memory_mb" {
     default = 4096  # Reduce from 8192
   }
   ```

2. **Deploy fewer VMs:**
   - Create only manager cluster first
   - Deploy apps cluster later

## Debugging Tips

### Enable Terraform Debug Logging

```bash
# For Terraform:
export TF_LOG=debug
terraform apply

# For Proxmox provider:
export PROXMOX_LOG_LEVEL=debug
terraform apply
```

### Check Terraform State

```bash
# List all resources:
terraform state list

# View specific resource:
terraform state show 'pve_qemu.vm["manager-1"]'

# Full state dump:
terraform state pull | jq .
```

### Monitor Proxmox Tasks

```bash
# Via Proxmox CLI:
pvesh get /nodes/pve1/tasks

# Via web UI:
Datacenter → Tasks → View logs
```

### Check VM Console

```bash
# Via Proxmox web UI:
VMs → Select VM → Console
# Monitor cloud-init and system startup
```

## Destroy Issues

### Issue: `terraform destroy` fails with RBD permission error

**Error:**
```
rbd error: rbd: listing images failed: (13) Permission denied
Parameter verification failed.
```

**Root Cause:**
When set to `true` (the provider's previous default), the `delete_unreferenced_disks_on_destroy` parameter attempts to read RBD disk metadata during VM deletion. This requires elevated permissions on RBD-backed storage that API tokens may not possess, causing permission errors even though the VM deletion itself succeeds.

**Background on RBD:**
- **RBD** = RADOS Block Device (Ceph distributed storage)
- **When used**: Multiple Proxmox nodes share same storage pool
- **Permission model**: Ceph has granular permissions separate from Proxmox
- **The issue**: VM deletion only needs Proxmox permissions, but disk verification needs Ceph permissions
- **This project**: Uses `local-vm-zfs` (single-node ZFS storage) which doesn't have this problem
- **If you use RBD**: Ensure your API token has elevated `Datastore.*` permissions or disable disk verification (recommended)

**Status:**
- ✅ **FIXED in this project** (v0.90.0 of bpg/proxmox provider)
- ⚠️ **Not a documented provider issue** - RBD permission errors during destroy are not reported in the bpg/terraform-provider-proxmox GitHub issues tracker
- 📌 **Proxy root cause** - Appears to be a Proxmox backend limitation with RBD disk cleanup permissions, not a Terraform provider bug

**Solution (Already Implemented):**

The VM resource in `terraform/modules/proxmox_vm/main.tf` now includes:
```hcl
resource "proxmox_virtual_environment_vm" "vm" {
  # ... other configuration ...
  stop_on_destroy                    = true
  delete_unreferenced_disks_on_destroy = false  # Disable RBD disk cleanup
  purge_on_destroy                   = false    # Skip backup purge
}
```

**How This Works:**
- `stop_on_destroy = true`: Cleanly stops VMs before deletion
- `delete_unreferenced_disks_on_destroy = false`: **Skips problematic RBD disk metadata check**
- `purge_on_destroy = false`: Avoids backup cleanup (unnecessary for dev/test)

**What Gets Destroyed:**
✅ VM configurations are fully deleted
✅ VM disks are fully deleted
✅ Terraform state is cleaned
❌ Disk cleanup doesn't attempt RBD metadata reads (avoiding permission errors)

The RBD disks are still physically deleted by Proxmox; we just skip the provider's secondary verification step.

**If Destroy Still Fails:**

1. **Check terraform state:**
   ```bash
   cd terraform
   terraform state list
   ```

2. **If resources still exist**, manually delete remaining VMs:
   ```bash
   # List resources
   terraform state list
   
   # Remove individual resources to allow destroy to continue
   terraform state rm 'module.rancher_manager.proxmox_virtual_environment_vm.vm["rancher-manager-1"]'
   
   # Retry destroy
   terraform destroy -auto-approve
   ```

3. **Manual Proxmox API deletion** (last resort):
   ```bash
   # Using Proxmox API
   curl -X DELETE \
     -H "Authorization: PVEAPIToken=user@pam:tokenid=secret" \
     https://proxmox.example.com:8006/api2/json/nodes/pve1/qemu/401
   ```

**Known Provider Limitations:**

The `delete_unreferenced_disks_on_destroy` parameter was hardcoded in early provider versions. It was made configurable in v0.90+ (merged Nov 2025). This project uses v0.90.0+ with the parameter explicitly disabled to avoid RBD permission issues.

**Prevention for Future Deployments:**

Always ensure your Terraform configuration includes:
```hcl
delete_unreferenced_disks_on_destroy = false
purge_on_destroy = false
```

When using RBD-backed storage in Proxmox.

## Downstream Cluster Registration Issues

### Issue: cattle-cluster-agent pods failing or not starting

**Symptom:** Pods created but stuck in Error state, restarting frequently

**Root Cause:** This was a common issue with the old system-agent-install.sh approach. The deployment now uses manifest-based registration which is much more reliable.

**Current Status (January 4, 2026):**
✅ Manifest-based registration (manifestUrl) is the **recommended and default approach**
- Self-contained Kubernetes manifests (no external script downloads)
- Automatic CA certificate configuration
- cattle-cluster-agent pods deploy successfully and register with Rancher

**If you still experience issues:**

1. **Verify manifest was applied successfully:**
   ```bash
   ssh ubuntu@192.168.1.110
   sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml \
     get pods -n cattle-system
   ```

2. **Check pod logs for error details:**
   ```bash
   ssh ubuntu@192.168.1.110
   sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml \
     logs -n cattle-system cattle-cluster-agent-<pod-hash> --tail=50
   ```

3. **Verify cluster object exists in Rancher Manager:**
   ```bash
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl get clusters.management.cattle.io c-7c2vb
   ```

4. **Check Rancher logs for rejection messages:**
   ```bash
   export KUBECONFIG=~/.kube/rancher-manager.yaml
   kubectl logs -n cattle-system -l app=rancher --tail=100 | grep -i cluster
   ```

### Issue: Manifest URL request times out or returns 404

**Symptom:** Error fetching `/v3/import/{token}_{cluster-id}.yaml`

**Solutions:**

1. **Verify API token is valid:**
   ```bash
   curl -sk -H "Authorization: Bearer $(cat ~/.kube/.rancher-api-token)" \
     https://rancher.example.com/v3/clusters
   # Should return cluster list without error
   ```

2. **Verify cluster ID is correct:**
   ```bash
   # Cluster ID format: c-7c2vb
   # Token format: rwn6w7kn48pzczv22xxz6cw6lsltfslst6bqm4shnjzh7pcqrkx7cl
   curl -sk -H "Authorization: Bearer $TOKEN" \
     https://rancher.example.com/v3/import/$TOKEN_c-7c2vb.yaml
   ```

3. **Check Rancher API is accessible from cluster nodes:**
   ```bash
   ssh ubuntu@192.168.1.110
   curl -sk https://rancher.example.com/health
   nslookup rancher.example.com
   ```

### Legacy Issue: system-agent-install.sh script timeout

**Status:** ⚠️ **DEPRECATED** - Use manifest-based approach instead

**What was the problem?**
```
ERROR: https://rancher.example.com/ping is not accessible (Could not resolve host: rancher.dataknife.net)
curl: (28) Operation timed out after 60002 milliseconds with 0 bytes received
```

**Root cause:**
The old system-agent-install.sh script relies on the `/v3/connect/agent` endpoint which doesn't respond reliably from external nodes. The script would hang for 60+ seconds trying to fetch connection information.

**Why we switched to manifest-based:**
- ✅ Uses public `/v3/import/{token}` endpoint (not internal `/v3/connect/agent`)
- ✅ Provides self-contained YAML manifest
- ✅ No external script downloads required
- ✅ Works on networks with strict egress controls
- ✅ Includes proper CA certificate configuration

**If you encounter this in old modules:**
- The `system_agent_install` module in `terraform/modules/` is **deprecated**
- Use `rancher_downstream_registration` module instead
- Old module kept for reference only, disabled by default

## Still Having Issues?

1. **Gather diagnostics:**
   ```bash
   terraform state list
   terraform show > state-dump.txt
   export TF_LOG=debug
   terraform plan > plan.txt 2>&1
   ```

2. **Check documentation:**
   - [RANCHER_DOWNSTREAM_MANAGEMENT.md](RANCHER_DOWNSTREAM_MANAGEMENT.md) - Cluster registration guide
   - [MODULES_AND_AUTOMATION.md](MODULES_AND_AUTOMATION.md) - Terraform modules
   - [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough

3. **Review logs:**
   - Proxmox task history (Datacenter → Tasks)
   - VM console logs (VMs → Select VM → Console)
   - Terraform debug output (TF_LOG=debug)
   - Rancher logs (kubectl logs -n cattle-system)

## DNS Issues

### Issue: Pods cannot resolve external DNS names

**Symptom**: Pods fail to resolve domains like `rancher.dataknife.net`

**Root Cause**: DNS is configured at node level via `/etc/resolv.conf`. CoreDNS pods inherit DNS from the node automatically.

**Solutions**:

1. **Check node DNS configuration**:
   ```bash
   ssh ubuntu@<node-ip>
   cat /etc/resolv.conf
   # Should show DNS servers, not 127.0.0.53
   ```

2. **Verify systemd-resolved is disabled**:
   ```bash
   systemctl status systemd-resolved
   # Should show: inactive (dead)
   ```

3. **Check CoreDNS pod DNS**:
   ```bash
   kubectl exec -n kube-system <coredns-pod> -- cat /etc/resolv.conf
   # Should match node /etc/resolv.conf
   ```

4. **Test DNS resolution**:
   ```bash
   # From node
   nslookup rancher.dataknife.net
   
   # From pod
   kubectl run -it --rm --restart=Never --image=busybox dns-test -- nslookup rancher.dataknife.net
   ```

**If DNS is incorrect**: Update Terraform variables and redeploy:
```hcl
# terraform/terraform.tfvars
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]
  }
}
```

See [DNS_CONFIGURATION_GUIDE.md](DNS_CONFIGURATION_GUIDE.md) for complete DNS troubleshooting.

## Related Documentation

- [DNS_CONFIGURATION_GUIDE.md](DNS_CONFIGURATION_GUIDE.md) - Complete DNS configuration and troubleshooting
- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [MODULES_AND_AUTOMATION.md](MODULES_AND_AUTOMATION.md) - Terraform modules
