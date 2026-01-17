# MetalLB Load Balancer Setup Guide

**Last Updated**: January 2025

## Overview

MetalLB provides a network load-balancer implementation for Kubernetes clusters that don't run on cloud providers. This guide covers installing MetalLB on RKE2 clusters to enable LoadBalancer service type support for Envoy Gateway and other services.

**UniFi Gateway Compatibility**: MetalLB Layer 2 mode works natively with UniFi Gateways (UDM, UDM-Pro, UXG, etc.) - no BGP required! UniFi Gateways don't support BGP, but MetalLB's ARP-based Layer 2 mode is perfect for UniFi environments.

## Why MetalLB?

- ✅ Native Kubernetes LoadBalancer support on bare metal/Proxmox
- ✅ Works seamlessly with Envoy Gateway
- ✅ Simple installation and configuration
- ✅ Layer 2 mode (ARP-based) works without network infrastructure changes
- ✅ **Works perfectly with UniFi Gateways** (no BGP required)
- ✅ No external hardware required

## Architecture

```
Internet/Router
    ↓
MetalLB LoadBalancer IP (e.g., 192.168.1.200)
    ↓
Envoy Gateway Service (LoadBalancer type)
    ↓
Envoy Gateway Pods (on worker nodes: 192.168.1.113-115)
    ↓
Application Services (via HTTPRoute)
```

## Prerequisites

- RKE2 cluster with worker nodes configured
- At least one IP address available in your subnet for MetalLB (outside of cluster node IPs)
- Access to the cluster via kubectl
- For NPRD-apps cluster: Worker nodes at `192.168.1.113`, `192.168.1.114`, `192.168.1.115`
- For PRD-apps cluster: Worker nodes at `192.168.1.123`, `192.168.1.124`, `192.168.1.125`

## Installation Methods

### Option 1: Terraform Installation (Recommended)

MetalLB is automatically installed on all downstream clusters when using Terraform with the `install_metallb = true` variable.

**Configuration in `terraform.tfvars`:**

```hcl
# Enable MetalLB installation
install_metallb = true

# MetalLB version (latest: v0.15.3)
# See https://metallb.universe.tf/release-notes/ for latest version
metallb_version = "v0.15.3"

# IP address pools per cluster
metallb_ip_pools = {
  nprd-apps = {
    addresses = "192.168.1.200-192.168.1.210"  # 11 IPs for LoadBalancer services
  }
  prd-apps = {
    addresses = "192.168.1.220-192.168.1.230"  # 11 IPs for LoadBalancer services
  }
  poc-apps = {
    addresses = "192.168.1.240-192.168.1.250"  # 11 IPs for LoadBalancer services
  }
}
```

**Deploy with Terraform:**

```bash
cd terraform
terraform plan
terraform apply
```

The MetalLB module will:
1. Install MetalLB CRDs and components
2. Configure IP address pools per cluster
3. Set up L2Advertisement for Layer 2 mode
4. Verify installation and pod readiness

### Option 2: Manual Installation

If you prefer to install MetalLB manually or need to configure it outside of Terraform, follow the steps below.

## Manual Installation Steps

### Step 1: Install MetalLB

```bash
# Set context for nprd-apps cluster
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Install MetalLB using kubectl (version 0.15.3 - check for latest)
# Latest version: v0.15.3 (see https://metallb.universe.tf/release-notes/)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml

# Wait for MetalLB to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

**Alternative: Helm Installation**

```bash
# Add MetalLB Helm repository
helm repo add metallb https://metallb.github.io/metallb
helm repo update

# Install MetalLB via Helm
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --version 0.15.3
```

### Step 2: Configure IP Address Pool

MetalLB needs an IP address pool to allocate LoadBalancer IPs from. This should be a range of IPs in your subnet that are NOT used by nodes or other services.

**For NPRD-apps cluster (subnet: 192.168.1.0/24):**

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nprd-apps-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.200-192.168.1.210  # 11 IPs for LoadBalancer services
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nprd-apps-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - nprd-apps-pool
EOF
```

**For PRD-apps cluster (subnet: 192.168.1.0/24):**

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: prd-apps-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.220-192.168.1.230  # 11 IPs for LoadBalancer services
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: prd-apps-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - prd-apps-pool
EOF
```

**Important**: Choose IP addresses that are:
- In the same subnet as your cluster nodes (192.168.1.0/24)
- Not assigned to any nodes or other services
- Not in DHCP range if using DHCP
- Example safe ranges:
  - NPRD-apps: `192.168.1.200-192.168.1.210`
  - PRD-apps: `192.168.1.220-192.168.1.230`
  - POC-apps: `192.168.1.240-192.168.1.250`

### Step 3: Verify MetalLB Installation

```bash
# Check MetalLB pods
kubectl get pods -n metallb-system

# Check IP address pool
kubectl get ipaddresspool -n metallb-system

# Check L2Advertisement
kubectl get l2advertisement -n metallb-system
```

Expected output:
```
NAME                                      READY   STATUS    RESTARTS   AGE
metallb-controller-xxxxx                  1/1     Running   0          2m
metallb-speaker-xxxxx                     1/1     Running   0          2m
metallb-speaker-yyyyy                     1/1     Running   0          2m
metallb-speaker-zzzzz                     1/1     Running   0          2m
```

## Configuring Envoy Gateway with MetalLB

### NPRD-apps Cluster

#### Step 1: Update Envoy Gateway Service to LoadBalancer

```bash
# Set context for nprd-apps cluster
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Get current Envoy Gateway service
kubectl get svc -n envoy-gateway-system

# Patch service to use LoadBalancer type
kubectl patch svc eg-envoy-gateway -n envoy-gateway-system \
  -p '{"spec":{"type":"LoadBalancer"}}'

# Verify the service gets an external IP
kubectl get svc eg-envoy-gateway -n envoy-gateway-system
```

Expected output:
```
NAME              TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
eg-envoy-gateway  LoadBalancer   10.43.x.x       192.168.1.200  80:xxxxx/TCP,443:xxxxx/TCP   5m
```

The `EXTERNAL-IP` should show an IP from your MetalLB pool (e.g., `192.168.1.200`).

#### Step 2: Configure DNS

Point your DNS to the LoadBalancer IP:

```bash
# Example: If Envoy Gateway LoadBalancer IP is 192.168.1.200
# Create DNS A record:
nprd-gateway.example.com  A  192.168.1.200
```

### PRD-apps Cluster

#### Step 1: Update Envoy Gateway Service to LoadBalancer

```bash
# Set context for prd-apps cluster
export KUBECONFIG=~/.kube/prd-apps.yaml

# Get current Envoy Gateway service
kubectl get svc -n envoy-gateway-system

# Patch service to use LoadBalancer type
kubectl patch svc eg-envoy-gateway -n envoy-gateway-system \
  -p '{"spec":{"type":"LoadBalancer"}}'

# Verify the service gets an external IP
kubectl get svc eg-envoy-gateway -n envoy-gateway-system
```

Expected output:
```
NAME              TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
eg-envoy-gateway  LoadBalancer   10.43.x.x       192.168.1.220  80:xxxxx/TCP,443:xxxxx/TCP   5m
```

The `EXTERNAL-IP` should show an IP from your MetalLB pool (e.g., `192.168.1.220`).

#### Step 2: Configure DNS

Point your DNS to the LoadBalancer IP:

```bash
# Example: If Envoy Gateway LoadBalancer IP is 192.168.1.220
# Create DNS A record:
prd-gateway.example.com  A  192.168.1.220
```

### POC-apps Cluster

Follow the same steps as NPRD-apps, but use:
- Kubeconfig: `~/.kube/poc-apps.yaml`
- Expected LoadBalancer IP: `192.168.1.240-192.168.1.250` range
- DNS: `poc-gateway.example.com`

Or update existing DNS to point to the LoadBalancer IP instead of individual worker node IPs.

## Testing the Setup

### Test 1: Verify LoadBalancer IP Assignment

```bash
# Check service status
kubectl get svc eg-envoy-gateway -n envoy-gateway-system -o wide

# Verify IP is assigned from MetalLB pool
kubectl describe svc eg-envoy-gateway -n envoy-gateway-system | grep -i "external ip\|loadbalancer"
```

### Test 2: Test Connectivity

```bash
# Test HTTP connectivity to LoadBalancer IP
curl -v http://192.168.1.200

# Test via DNS (if configured)
curl -v http://nprd-gateway.example.com
```

### Test 3: Verify Load Balancing

MetalLB with Layer 2 mode will automatically load balance traffic across worker nodes running Envoy Gateway pods:

```bash
# Check which nodes have Envoy Gateway pods
kubectl get pods -n envoy-gateway-system -o wide

# Traffic should be distributed across all worker nodes
```

## Advanced Configuration

### Multiple IP Pools

You can create multiple IP pools for different purposes:

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nprd-apps-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.200-192.168.1.210
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nprd-apps-reserved-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.211-192.168.1.220
  autoAssign: false  # Requires manual assignment via service annotation
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nprd-apps-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - nprd-apps-pool
  - nprd-apps-reserved-pool
EOF
```

To use the reserved pool, annotate your service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    metallb.universe.tf/address-pool: nprd-apps-reserved-pool
spec:
  type: LoadBalancer
  # ...
```

### BGP Mode (Advanced) - Not Supported by UniFi

**Note**: UniFi Gateways (UDM, UDM-Pro, UXG, etc.) do **NOT** support BGP. Use Layer 2 mode instead (which works perfectly with UniFi).

If you have a BGP-capable router (not UniFi), you can use BGP mode:

```bash
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: nprd-apps-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
  - nprd-apps-pool
  peers:
  - name: router1
    peerAddress: 192.168.1.1
    peerASN: 65000
    myASN: 65001
EOF
```

**For UniFi users**: Stick with Layer 2 mode (L2Advertisement) - it's simpler and works natively with UniFi.

## Troubleshooting

### Issue: Service shows "pending" external IP

**Solution**: Check MetalLB configuration:

```bash
# Check MetalLB pods are running
kubectl get pods -n metallb-system

# Check IP pool configuration
kubectl get ipaddresspool -n metallb-system -o yaml

# Check MetalLB logs
kubectl logs -n metallb-system -l app=metallb
```

### Issue: Cannot connect to LoadBalancer IP

**Solution**: Verify IP is in same subnet as nodes:

```bash
# Check node IPs
kubectl get nodes -o wide

# Ensure LoadBalancer IP is in same subnet
# Nodes: 192.168.1.113-115
# LoadBalancer should be: 192.168.1.x (same subnet)
```

### Issue: ARP conflicts

**Solution**: Ensure IP pool doesn't conflict with existing devices:

```bash
# Ping IPs in your pool range to check for conflicts
ping 192.168.1.200
ping 192.168.1.201
# If these respond, they're in use - choose different range
```

### View MetalLB Status

```bash
# Check MetalLB speaker status (shows ARP announcements)
kubectl logs -n metallb-system -l app=metallb,component=speaker

# Check MetalLB controller status
kubectl logs -n metallb-system -l app=metallb,component=controller
```

## Integration with Existing Setup

### Update DNS Configuration

Update `docs/DNS_CONFIGURATION.md` to use LoadBalancer IP instead of round-robin worker IPs:

```bash
# Before (NodePort with DNS round-robin):
nprd-apps-wk.example.com  A  192.168.1.113
nprd-apps-wk.example.com  A  192.168.1.114
nprd-apps-wk.example.com  A  192.168.1.115

# After (MetalLB LoadBalancer):
nprd-apps-wk.example.com  A  192.168.1.200
```

### Update Gateway API Documentation

The `docs/GATEWAY_API_SETUP.md` should be updated to mention MetalLB as the recommended LoadBalancer solution for bare metal/Proxmox environments.

## Multi-Cluster Configuration

### IP Pool Allocation

For each cluster (nprd-apps, prd-apps, poc-apps), configure separate IP pools to avoid conflicts:

| Cluster | IP Pool Range | LoadBalancer Example IPs |
|---------|---------------|-------------------------|
| **nprd-apps** | `192.168.1.200-192.168.1.210` | `192.168.1.200`, `192.168.1.201`, etc. |
| **prd-apps** | `192.168.1.220-192.168.1.230` | `192.168.1.220`, `192.168.1.221`, etc. |
| **poc-apps** | `192.168.1.240-192.168.1.250` | `192.168.1.240`, `192.168.1.241`, etc. |

This ensures no IP conflicts between clusters.

### Envoy Gateway LoadBalancer IPs

After configuring MetalLB and updating Envoy Gateway services:

- **NPRD-apps**: Envoy Gateway will get an IP from `192.168.1.200-192.168.1.210`
- **PRD-apps**: Envoy Gateway will get an IP from `192.168.1.220-192.168.1.230`
- **POC-apps**: Envoy Gateway will get an IP from `192.168.1.240-192.168.1.250`

### DNS Configuration for PRD-apps

Update your DNS to point to PRD-apps LoadBalancer IP:

```bash
# Example: If Envoy Gateway LoadBalancer IP is 192.168.1.220
# Create DNS A record:
prd-gateway.example.com  A  192.168.1.220

# Or update existing DNS:
prd-apps-wk.example.com  A  192.168.1.220  # Single IP instead of round-robin
```

**Before (NodePort with DNS round-robin):**
```
prd-apps-wk.example.com  A  192.168.1.123
prd-apps-wk.example.com  A  192.168.1.124
prd-apps-wk.example.com  A  192.168.1.125
```

**After (MetalLB LoadBalancer):**
```
prd-apps-wk.example.com  A  192.168.1.220
```

## Security Considerations

1. **ARP Spoofing**: MetalLB Layer 2 mode uses ARP, which can be spoofed. Ensure network security.
2. **Network Isolation**: Use VLANs to isolate traffic if needed.
3. **Firewall Rules**: Ensure firewall rules allow traffic to LoadBalancer IPs.

## UniFi Gateway Integration

### How MetalLB Works with UniFi

MetalLB Layer 2 mode uses **ARP** (Address Resolution Protocol) to announce LoadBalancer IPs on your network. UniFi Gateways fully support ARP, so no special configuration is needed:

1. **MetalLB assigns a LoadBalancer IP** (e.g., `192.168.1.200`)
2. **MetalLB announces the IP via ARP** - UniFi Gateway learns about it automatically
3. **Traffic to that IP routes through UniFi** to your cluster nodes
4. **Envoy Gateway pods receive traffic** and route to your applications

### Optional: UniFi Port Forwarding (External Access)

If you need to expose services externally (from internet), configure port forwarding on your UniFi Gateway:

**UniFi Network → Firewall & Security → Port Forwarding**

1. Add a new port forwarding rule:
   - **Name**: `nprd-apps-envoy-gateway`
   - **Interface**: WAN
   - **Protocol**: TCP
   - **Port Range**: 80, 443 (or your desired ports)
   - **Forward to**: Your MetalLB LoadBalancer IP (e.g., `192.168.1.200`)
   - **Forward Port**: Same as port range (80, 443)

This allows:
- **External traffic** → UniFi Gateway → Port Forward → MetalLB IP (`192.168.1.200`)
- **Internal traffic** → Direct access to MetalLB IP (`192.168.1.200`)

### UniFi Static Routes (Alternative)

If you prefer routing-based approach instead of port forwarding:

**UniFi Network → Routing → Static Routes**

- **Destination Network**: `192.168.1.200/32` (your MetalLB LoadBalancer IP)
- **Route Type**: Interface Route
- **Interface**: Your LAN/VLAN interface
- **Gateway**: Cluster node IP (e.g., `192.168.1.113`)

**Note**: MetalLB Layer 2 mode typically doesn't require static routes - ARP handles routing automatically.

### Why Layer 2 Mode is Best for UniFi

✅ **No BGP needed** - UniFi doesn't support BGP anyway  
✅ **Works out of the box** - ARP is standard networking  
✅ **Automatic failover** - MetalLB handles node failures  
✅ **No router configuration** - UniFi Gateway learns routes via ARP  
✅ **Simple setup** - Just configure IP pool in Kubernetes

## References

- [MetalLB Official Documentation](https://metallb.universe.tf/)
- [MetalLB Installation Guide](https://metallb.universe.tf/installation/)
- [MetalLB Configuration](https://metallb.universe.tf/configuration/)
- [MetalLB Layer 2 Mode](https://metallb.universe.tf/concepts/layer2/)
