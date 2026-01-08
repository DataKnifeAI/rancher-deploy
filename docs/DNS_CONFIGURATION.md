# DNS Configuration for Rancher Deploy

This guide documents the DNS records required for Rancher Kubernetes cluster deployment on Proxmox.

## Overview

The Rancher deployment requires DNS records pointing to the manager cluster nodes for Rancher UI access and Kubernetes API access.

## Required DNS Records

### 1. Manager Cluster API Server

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

### 2. Rancher Management UI

**Purpose**: Access Rancher web interface for cluster and application management

| Record Type | Hostname | Type | Target | Purpose |
|---|---|---|---|---|
| **CNAME Record** | `rancher.example.com` | CNAME | `manager.example.com` | Rancher UI access via ingress controller |

**Example (DNS provider format)**:
```
rancher.example.com    CNAME    manager.example.com
```

**Result**: Resolves to the same IPs as `manager.example.com` (all 3 nodes)

### 3. NPRD Apps Cluster

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

### 4. PRD Apps Cluster

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

## Current Configuration

Based on UniFi Network DNS configuration:

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

## Verification

### Check DNS Resolution

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

### Verify HTTP/HTTPS Access

```bash
# Test Rancher UI connectivity
curl -k https://rancher.example.com
# Should receive HTTP 200 and Rancher API response

# Test Kubernetes API
kubectl cluster-info
# Should show API server at https://manager.example.com:6443
```

## Why Round-Robin (Multiple A Records)?

The manager cluster uses **round-robin DNS** with multiple A records pointing to all 3 manager nodes because:

1. **Load Distribution**: Connections are distributed across all 3 nodes
2. **High Availability**: If one node is down, DNS still resolves to the other 2
3. **Service Redundancy**: Kubernetes API server runs on all manager nodes
4. **Ingress Controller**: Rancher ingress controller runs on all nodes for HA

## DNS Configuration in UniFi

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

## Troubleshooting

### DNS Not Resolving

1. **Verify DNS Server**: Check that UniFi controller is authoritative for domain
   ```bash
   nslookup -type=NS example.com
   # Should show your UniFi DNS server
   ```

2. **Check UniFi DNS Records**: Verify records exist in UniFi Network UI
   - Network → Settings → Advanced → DNS Records
   - Confirm all A records are created

3. **Flush DNS Cache** (if on local machine):
   ```bash
   sudo systemctl restart systemd-resolved  # Linux
   ipconfig /flushdns                       # Windows
   ```

### DNS Resolving But Rancher Not Accessible

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

## kubectl Tools for Multi-Cluster Management

After DNS is configured and clusters are deployed, you can improve your kubectl experience with optional tools:

### kubectx - Cluster Context Switching

`kubectx` allows you to easily switch between multiple Kubernetes clusters, similar to how `cd` works for directories:

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

### kubens - Namespace Switching

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

### Installation

```bash
# Method 1: Using Makefile (recommended)
make install-kubectl-tools

# Method 2: Manual installation
git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

These tools significantly improve developer experience when managing multiple Kubernetes clusters.

## Related Documentation

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Kubernetes & Rancher deployment with kubectl tools setup
- [TERRAFORM_VARIABLES.md](TERRAFORM_VARIABLES.md) - Configuration variables
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Deployment troubleshooting
