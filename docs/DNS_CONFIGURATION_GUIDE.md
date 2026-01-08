# DNS Configuration Guide

Complete guide to DNS configuration for Rancher clusters deployed on Proxmox.

## Overview

DNS configuration is handled at the **node level** using `/etc/resolv.conf`. CoreDNS pods automatically inherit DNS configuration from the node, eliminating the need for CoreDNS ConfigMap patching.

## Architecture

### DNS Flow

```
Terraform Variables (dns_servers)
    ↓
Cloud-init (disable systemd-resolved, configure /etc/resolv.conf)
    ↓
/etc/resolv.conf (direct DNS server configuration)
    ↓
CoreDNS pods (/etc/resolv.conf inherited from node)
    ↓
Application pods (query CoreDNS, which uses node DNS)
```

### Key Principles

1. **Single Source of Truth**: DNS configured at node level via `/etc/resolv.conf`
2. **Automatic Inheritance**: CoreDNS pods inherit `/etc/resolv.conf` from the node
3. **No Patching Required**: No CoreDNS ConfigMap patching needed
4. **Simple Configuration**: Change DNS servers in Terraform variables, not hardcoded values

## Configuration

### Terraform Variables

DNS servers are configured via Terraform variables:

```hcl
# terraform/terraform.tfvars
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]  # Local DNS + Cloudflare
  }
  nprd-apps = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]
  }
}
```

### Node DNS Configuration

During VM provisioning, cloud-init:
1. **Disables systemd-resolved**: Prevents DNS conflicts
2. **Configures `/etc/resolv.conf`**: Direct DNS server configuration
3. **Makes resolv.conf immutable**: Prevents overwrites

**Location**: `terraform/modules/proxmox_vm/cloud-init-rke2.sh`

```bash
# Stop and disable systemd-resolved
systemctl stop systemd-resolved
systemctl disable systemd-resolved

# Configure /etc/resolv.conf directly
cat > /etc/resolv.conf <<EOF
nameserver 192.168.1.1
nameserver 1.1.1.1
options edns0
EOF

# Make resolv.conf immutable
chattr +i /etc/resolv.conf
```

### CoreDNS Behavior

CoreDNS pods automatically inherit `/etc/resolv.conf` from the node:
- No CoreDNS ConfigMap patching needed
- No post-deployment scripts required
- DNS servers are read from node configuration automatically

## DNS Records Required

### Manager Cluster

**Purpose**: Kubernetes API server access and Rancher UI

| Record Type | Hostname | Type | IPs | Purpose |
|---|---|---|---|---|
| **A Record** | `manager.dataknife.net` | Round-robin | `192.168.1.100`, `192.168.1.101`, `192.168.1.102` | Kubernetes API load balancing |
| **CNAME** | `rancher.dataknife.net` | CNAME | `manager.dataknife.net` | Rancher UI access |

**Example DNS Configuration**:
```
manager.dataknife.net    A    192.168.1.100
manager.dataknife.net    A    192.168.1.101
manager.dataknife.net    A    192.168.1.102
rancher.dataknife.net    CNAME manager.dataknife.net
```

### Apps Cluster

**Purpose**: Non-production apps cluster API access

| Record Type | Hostname | Type | IPs | Purpose |
|---|---|---|---|---|
| **A Record** | `nprd-apps.dataknife.net` | Round-robin | `192.168.1.110`, `192.168.1.111`, `192.168.1.112` | Apps cluster API access |

**Example DNS Configuration**:
```
nprd-apps.dataknife.net  A    192.168.1.110
nprd-apps.dataknife.net  A    192.168.1.111
nprd-apps.dataknife.net  A    192.168.1.112
```

## Verification

### Check Node DNS Configuration

```bash
# SSH to any cluster node
ssh ubuntu@192.168.1.100

# Check /etc/resolv.conf
cat /etc/resolv.conf
# Should show:
# nameserver 192.168.1.1
# nameserver 1.1.1.1

# Verify systemd-resolved is disabled
systemctl status systemd-resolved
# Should show: inactive (dead)
```

### Check CoreDNS Pod DNS

```bash
# From manager cluster node
ssh ubuntu@192.168.1.100
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml \
  exec -n kube-system <coredns-pod> -- cat /etc/resolv.conf

# Should show same DNS servers as node
```

### Test DNS Resolution

```bash
# Test from node
ssh ubuntu@192.168.1.100
nslookup rancher.dataknife.net
# Should resolve to manager cluster IPs

# Test from pod
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml \
  run -it --rm --restart=Never --image=busybox dns-test -- nslookup rancher.dataknife.net

# Should resolve successfully
```

## Troubleshooting

### DNS Not Resolving in Pods

**Symptom**: Pods cannot resolve external domains

**Check 1: Node DNS Configuration**
```bash
ssh ubuntu@<node-ip>
cat /etc/resolv.conf
# Should show DNS servers, not 127.0.0.53
```

**Check 2: CoreDNS Pod DNS**
```bash
kubectl exec -n kube-system <coredns-pod> -- cat /etc/resolv.conf
# Should match node /etc/resolv.conf
```

**Check 3: CoreDNS Logs**
```bash
kubectl logs -n kube-system -l k8s-app=rke2-coredns-rke2-coredns --tail=50
# Look for forward errors or DNS resolution issues
```

**Solution**: If `/etc/resolv.conf` is incorrect, fix at node level:
```bash
# On node
sudo chattr -i /etc/resolv.conf  # Remove immutable flag
sudo vi /etc/resolv.conf          # Edit with correct DNS servers
sudo chattr +i /etc/resolv.conf   # Make immutable again
```

### DNS Servers Not Applied

**Symptom**: `/etc/resolv.conf` shows wrong DNS servers

**Check cloud-init logs**:
```bash
ssh ubuntu@<node-ip>
cat /var/log/rke2-install.log | grep -i dns
```

**Verify Terraform variables**:
```bash
cd terraform
terraform console
> var.clusters["manager"].dns_servers
```

**Solution**: Update Terraform variables and redeploy:
```hcl
# terraform/terraform.tfvars
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]  # Update here
  }
}
```

### systemd-resolved Still Running

**Symptom**: `/etc/resolv.conf` points to `127.0.0.53` (systemd-resolved stub)

**Check**:
```bash
systemctl status systemd-resolved
```

**Solution**:
```bash
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo chattr -i /etc/resolv.conf
# Edit /etc/resolv.conf with correct DNS servers
sudo chattr +i /etc/resolv.conf
```

## DNS Server Selection

### Recommended DNS Servers

- **Local DNS/Gateway**: `192.168.1.1` (or your network gateway)
  - Resolves internal domains (e.g., `*.dataknife.net`)
  - Faster resolution for local resources
  
- **Public DNS Fallback**: `1.1.1.1` (Cloudflare) or `8.8.8.8` (Google)
  - Used when local DNS doesn't resolve
  - Provides internet DNS resolution

### Finding Your DNS Servers

```bash
# Check current DNS configuration
cat /etc/resolv.conf

# Check network gateway (usually DNS server)
ip route | grep default

# Test DNS resolution
nslookup rancher.dataknife.net 192.168.1.1
```

## Environment-Specific Configuration

### Development Environment

```hcl
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]
  }
}
```

### Production Environment

```hcl
clusters = {
  manager = {
    dns_servers = ["10.0.1.1", "10.0.1.2"]  # Internal DNS servers
  }
  nprd-apps = {
    dns_servers = ["10.0.1.1", "10.0.1.2"]
  }
}
```

## Migration from Old Approach

If you have existing clusters with CoreDNS ConfigMap patching:

1. **Update Terraform variables** with correct DNS servers
2. **Redeploy nodes** to apply new DNS configuration
3. **Verify** CoreDNS pods inherit node DNS automatically
4. **Remove** any post-deployment CoreDNS patching scripts

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - DNS troubleshooting
- [DNS_CONFIGURATION.md](DNS_CONFIGURATION.md) - DNS records for Rancher
