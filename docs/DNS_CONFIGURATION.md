# DNS Configuration Guide

**Last Updated**: January 2025

Complete guide to DNS configuration for Rancher Kubernetes clusters deployed on Proxmox. This covers both DNS records (for cluster access) and DNS server configuration (for node-level DNS resolution).

## Overview

DNS configuration has two components:

1. **DNS Records**: Required for accessing Rancher UI and Kubernetes API (configured in your DNS provider)
2. **DNS Servers**: Node-level DNS server configuration for resolving domains (configured via Terraform)

## Table of Contents

1. [DNS Records Configuration](#dns-records-configuration) - Required DNS records for clusters
2. [DNS Server Configuration](#dns-server-configuration) - Node-level DNS server setup
3. [Architecture](#architecture) - How DNS flows through the system
4. [Verification](#verification) - Testing DNS configuration
5. [Troubleshooting](#troubleshooting) - Common DNS issues and solutions
6. [Tools](#tools) - kubectl tools for multi-cluster management

## DNS Records Configuration

DNS records are required for Rancher UI access and Kubernetes API server access. These are configured in your DNS provider (e.g., UniFi Network, BIND, or cloud DNS).

### Required DNS Records

#### 1. Manager Cluster API Server

**Purpose**: Kubernetes API server access for cluster management

| Record Type | Hostname | Type | IPs | Purpose |
|---|---|---|---|---|
| **A Record** | `manager.example.com` | Round-robin | `192.168.1.100`, `192.168.1.101`, `192.168.1.102` | Kubernetes API load balancing across 3 manager nodes |

**Example (DNS provider format)**:
```
manager.example.com    A    192.168.1.100
manager.example.com    A    192.168.1.101
manager.example.com    A    192.168.1.102
```

#### 2. Rancher Management UI

**Purpose**: Access Rancher web interface for cluster and application management

| Record Type | Hostname | Type | Target | Purpose |
|---|---|---|---|---|
| **CNAME Record** | `rancher.example.com` | CNAME | `manager.example.com` | Rancher UI access via ingress controller |

**Example (DNS provider format)**:
```
rancher.example.com    CNAME    manager.example.com
```

**Result**: Resolves to the same IPs as `manager.example.com` (all 3 nodes)

#### 3. NPRD Apps Cluster

**Purpose**: Non-production apps cluster API access and ingress

| Record Type | Hostname | Type | IPs | Purpose |
|---|---|---|---|---|
| **A Record** | `nprd-apps.example.com` | Round-robin | `192.168.1.110`, `192.168.1.111`, `192.168.1.112` | NPRD apps cluster API and ingress load balancing (server nodes) |
| **CNAME Record** | `nprd.example.com` | CNAME | `nprd-apps.example.com` | Alias for NPRD cluster access |

**Example (DNS provider format)**:
```
nprd-apps.example.com  A    192.168.1.110
nprd-apps.example.com  A    192.168.1.111
nprd-apps.example.com  A    192.168.1.112
nprd.example.com       CNAME nprd-apps.example.com
```

#### 4. PRD Apps Cluster

**Purpose**: Production apps cluster API access and ingress

| Record Type | Hostname | Type | IPs | Purpose |
|---|---|---|---|---|
| **A Record** | `prd-apps.example.com` | Round-robin | `192.168.1.120`, `192.168.1.121`, `192.168.1.122` | PRD apps cluster API and ingress load balancing (server nodes) |
| **CNAME Record** | `prd.example.com` | CNAME | `prd-apps.example.com` | Alias for PRD cluster access |

**Example (DNS provider format)**:
```
prd-apps.example.com   A    192.168.1.120
prd-apps.example.com   A    192.168.1.121
prd-apps.example.com   A    192.168.1.122
prd.example.com        CNAME prd-apps.example.com
```

### DNS Records Structure

```
Host: rancher.example.com
├─ CNAME → manager.example.com
│
├─ manager.example.com (A records - round-robin)
│  ├─ 192.168.1.100 (rancher-manager-1)
│  ├─ 192.168.1.101 (rancher-manager-2)
│  └─ 192.168.1.102 (rancher-manager-3)
│
├─ nprd.example.com (CNAME)
│  └─ CNAME → nprd-apps.example.com
│
├─ nprd-apps.example.com (A records - round-robin, server nodes only)
│  ├─ 192.168.1.110 (nprd-apps-1)
│  ├─ 192.168.1.111 (nprd-apps-2)
│  └─ 192.168.1.112 (nprd-apps-3)
│  Note: Worker nodes (.113-.115) don't need DNS records
│
├─ prd.example.com (CNAME)
│  └─ CNAME → prd-apps.example.com
│
└─ prd-apps.example.com (A records - round-robin, server nodes only)
   ├─ 192.168.1.120 (prd-apps-1)
   ├─ 192.168.1.121 (prd-apps-2)
   └─ 192.168.1.122 (prd-apps-3)
   Note: Worker nodes (.123-.125) don't need DNS records
```

### Why Round-Robin (Multiple A Records)?

The manager cluster uses **round-robin DNS** with multiple A records pointing to all 3 manager nodes because:

1. **Load Distribution**: Connections are distributed across all 3 nodes
2. **High Availability**: If one node is down, DNS still resolves to the other 2
3. **Service Redundancy**: Kubernetes API server runs on all manager nodes
4. **Ingress Controller**: Rancher ingress controller runs on all nodes for HA

### DNS Configuration in UniFi

**Location**: UniFi Network → Network Settings → Advanced → DNS Records

```
Record Type: A Record
Hostname: manager.example.com
IP Address: 192.168.1.100
      (add additional A records for .101 and .102)

Record Type: CNAME Record
Hostname: rancher.example.com
Target: manager.example.com
```

## DNS Server Configuration

DNS server configuration is handled at the **node level** using `/etc/resolv.conf`. CoreDNS pods automatically inherit DNS configuration from the node, eliminating the need for CoreDNS ConfigMap patching.

### Architecture

#### DNS Flow

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

#### Key Principles

1. **Single Source of Truth**: DNS configured at node level via `/etc/resolv.conf`
2. **Automatic Inheritance**: CoreDNS pods inherit `/etc/resolv.conf` from the node
3. **No Patching Required**: No CoreDNS ConfigMap patching needed
4. **Simple Configuration**: Change DNS servers in Terraform variables, not hardcoded values

### Configuration

#### Terraform Variables

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
  prd-apps = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]
  }
}
```

#### Node DNS Configuration

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

#### CoreDNS Behavior

CoreDNS pods automatically inherit `/etc/resolv.conf` from the node:
- No CoreDNS ConfigMap patching needed
- No post-deployment scripts required
- DNS servers are read from node configuration automatically

### DNS Server Selection

#### Recommended DNS Servers

- **Local DNS/Gateway**: `192.168.1.1` (or your network gateway)
  - Resolves internal domains (e.g., `*.dataknife.net`)
  - Faster resolution for local resources
  
- **Public DNS Fallback**: `1.1.1.1` (Cloudflare) or `8.8.8.8` (Google)
  - Used when local DNS doesn't resolve
  - Provides internet DNS resolution

#### Finding Your DNS Servers

```bash
# Check current DNS configuration
cat /etc/resolv.conf

# Check network gateway (usually DNS server)
ip route | grep default

# Test DNS resolution
nslookup rancher.example.com 192.168.1.1
```

### Environment-Specific Configuration

#### Development Environment

```hcl
clusters = {
  manager = {
    dns_servers = ["192.168.1.1", "1.1.1.1"]
  }
}
```

#### Production Environment

```hcl
clusters = {
  manager = {
    dns_servers = ["10.0.1.1", "10.0.1.2"]  # Internal DNS servers
  }
  nprd-apps = {
    dns_servers = ["10.0.1.1", "10.0.1.2"]
  }
  prd-apps = {
    dns_servers = ["10.0.1.1", "10.0.1.2"]
  }
}
```

## Verification

### Check DNS Records Resolution

```bash
# Manager cluster DNS
nslookup manager.example.com
# Should return: 192.168.1.100, 192.168.1.101, 192.168.1.102

# Rancher UI DNS
nslookup rancher.example.com
# Should return CNAME to manager.example.com, then resolve to manager IPs

# NPRD Apps cluster DNS
nslookup nprd-apps.example.com
# Should return: 192.168.1.110, 192.168.1.111, 192.168.1.112

# NPRD cluster alias
nslookup nprd.example.com
# Should return CNAME to nprd-apps.example.com

# PRD Apps cluster DNS
nslookup prd-apps.example.com
# Should return: 192.168.1.120, 192.168.1.121, 192.168.1.122

# PRD cluster alias
nslookup prd.example.com
# Should return CNAME to prd-apps.example.com
```

### Check Node DNS Configuration

```bash
# SSH to any cluster node
ssh ubuntu@192.168.1.100

# Check /etc/resolv.conf
cat /etc/resolv.conf
# Should show:
# nameserver 192.168.1.1
# nameserver 1.1.1.1
# options edns0

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
nslookup rancher.example.com
# Should resolve to manager cluster IPs

# Test from pod
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml \
  run -it --rm --restart=Never --image=busybox dns-test -- nslookup rancher.example.com

# Should resolve successfully
```

### Verify HTTP/HTTPS Access

```bash
# Test Rancher UI connectivity
curl -k https://rancher.example.com
# Should receive HTTP 200 and Rancher API response

# Test Kubernetes API
kubectl cluster-info
# Should show API server at https://manager.example.com:6443
```

## Troubleshooting

### DNS Records Not Resolving

**Symptom**: DNS queries return no results or incorrect IPs

1. **Verify DNS Server**: Check that your DNS provider is authoritative for domain
   ```bash
   nslookup -type=NS example.com
   # Should show your DNS server
   ```

2. **Check DNS Records**: Verify records exist in your DNS provider UI
   - UniFi: Network → Settings → Advanced → DNS Records
   - Confirm all A records are created

3. **Flush DNS Cache** (if on local machine):
   ```bash
   sudo systemctl restart systemd-resolved  # Linux
   ipconfig /flushdns                       # Windows
   ```

### DNS Resolving But Rancher Not Accessible

**Symptom**: DNS resolves but can't access Rancher UI

1. **Verify Rancher is Running**:
   ```bash
   kubectl get ingress -n cattle-system
   # Should show rancher ingress with correct hostname
   ```

2. **Check Ingress Controller**:
   ```bash
   kubectl get svc -n kube-system | grep traefik
   # RKE2 uses Traefik ingress by default
   ```

3. **Test Direct IP Access**:
   ```bash
   curl -k https://192.168.1.100
   # If this works but DNS doesn't, DNS issue
   # If this fails, Rancher/Ingress issue
   ```

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

## Migration from Old Approach

If you have existing clusters with CoreDNS ConfigMap patching:

1. **Update Terraform variables** with correct DNS servers
2. **Redeploy nodes** to apply new DNS configuration
3. **Verify** CoreDNS pods inherit node DNS automatically
4. **Remove** any post-deployment CoreDNS patching scripts

## Tools

### kubectl Tools for Multi-Cluster Management

After DNS is configured and clusters are deployed, you can improve your kubectl experience with optional tools:

#### kubectx - Cluster Context Switching

`kubectx` allows you to easily switch between multiple Kubernetes clusters:

```bash
# Install using make target
make install-kubectl-tools

# List all cluster contexts
kubectx

# Switch to manager cluster
kubectx rancher-manager

# Switch to nprd-apps cluster
kubectx nprd-apps

# Switch to prd-apps cluster
kubectx prd-apps

# Switch back to previous cluster
kubectx -
```

#### kubens - Namespace Switching

`kubens` helps you switch between namespaces within a cluster:

```bash
# List namespaces
kubens

# Switch to kube-system namespace
kubens kube-system

# Switch to cattle-system (Rancher namespace)
kubens cattle-system

# Switch back to previous namespace
kubens -
```

#### Installation

```bash
# Method 1: Using Makefile (recommended)
make install-kubectl-tools

# Method 2: Manual installation
git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

## Additional Notes

### Certificate Considerations

- **Self-Signed Certificates**: RKE2 generates self-signed certificates for HTTPS
  - Use `curl -k` flag to skip TLS verification during testing
  - Browsers will show security warnings (expected for self-signed certs)

- **Production**: Consider implementing proper certificates via Let's Encrypt or your CA
  - Update Rancher Helm chart with certificate secrets
  - Configure cert-manager with proper ACME issuers

### Network Configuration

The deployment uses:
- **VLAN**: 14 (unified segment for all cluster nodes)
- **Subnet**: 192.168.1.0/24
- **Gateway**: 192.168.1.1
- **DNS**: 192.168.1.1 (upstream resolver)
- **Manager IPs**: 192.168.1.100-102
- **NPRD Apps Server IPs**: 192.168.1.110-112
- **NPRD Apps Worker IPs**: 192.168.1.113-115
- **PRD Apps Server IPs**: 192.168.1.120-122
- **PRD Apps Worker IPs**: 192.168.1.123-125

All DNS records reference the static IPs configured via cloud-init during VM provisioning.

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Complete deployment walkthrough
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - General troubleshooting guide
- [GATEWAY_API_SETUP.md](GATEWAY_API_SETUP.md) - Gateway API and Envoy Gateway setup
