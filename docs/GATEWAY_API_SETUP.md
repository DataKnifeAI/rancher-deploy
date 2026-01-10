# Gateway API Setup Guide

**Last Updated**: January 2025

## Overview

This guide covers setting up Gateway API on RKE2 clusters managed by Rancher. Gateway API is the evolution of the Ingress API in Kubernetes, providing more powerful routing capabilities, role-based access control, and better multi-tenancy support.

## Recommended Ingress Controllers

### 1. Envoy Gateway (Recommended) ⭐

**Why Choose Envoy Gateway:**
- ✅ Official Gateway API implementation from Gateway API SIG
- ✅ Lightweight and purpose-built for Gateway API
- ✅ Excellent multi-cluster support (perfect for Rancher)
- ✅ Active development and community support
- ✅ Works alongside existing Traefik (for legacy Ingress)

**Installation:**

Envoy Gateway can be installed using the official installation manifest:

```bash
# Install Gateway API CRDs first (if not already installed)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# Install Envoy Gateway using official manifest (version 1.6.1)
# On manager cluster
export KUBECONFIG=~/.kube/rancher-manager.yaml
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.6.1/install.yaml

# On nprd-apps cluster
export KUBECONFIG=~/.kube/nprd-apps.yaml
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.6.1/install.yaml

# Wait for deployment to be ready
kubectl wait --for=condition=available deployment/envoy-gateway -n envoy-gateway-system --timeout=5m

# Verify installation
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclass
```

**Note:** The Helm repository method is not currently available. Use the manifest installation method shown above.

**Note:** Envoy Gateway v1.6.1 uses Gateway API v1.4.1 internally, but Gateway API v1.0.0 CRDs are fully compatible.

**Basic Gateway Configuration:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: production-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    allowedRoutes:
      namespaces:
        from: All
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-cert
        kind: Secret
```

### 2. NGINX Kubernetes Gateway

**Why Choose NGINX Kubernetes Gateway:**
- ✅ Official NGINX implementation
- ✅ Production-hardened
- ✅ Enterprise support available
- ✅ Excellent performance
- ✅ Rich feature set

**Installation:**

```bash
# Install Gateway API CRDs first
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# Install NGINX Kubernetes Gateway
kubectl apply -f https://github.com/nginxinc/nginx-kubernetes-gateway/releases/download/v1.1.0/install.yaml

# Verify
kubectl get pods -n nginx-gateway
kubectl get gatewayclass
```

### 3. Traefik (Upgrade Path)

**Why Choose Traefik:**
- ✅ Already installed with RKE2
- ✅ Can be upgraded to support Gateway API
- ✅ Familiar configuration if already using Traefik
- ⚠️  May need to upgrade RKE2's bundled Traefik version

**Checking Current Traefik Version:**

```bash
kubectl get deployment traefik -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Note:** RKE2's bundled Traefik may not support Gateway API. You may need to install Traefik separately or upgrade RKE2.

**Installing Traefik with Gateway API Support:**

```bash
# Add Traefik Helm repo
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Install Traefik with Gateway API enabled
helm install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --set providers.kubernetesGateway.enabled=true
```

## Comparison Matrix

| Controller | Gateway API Support | Ease of Setup | Multi-Cluster | Production Ready | Notes |
|------------|---------------------|---------------|---------------|------------------|-------|
| **Envoy Gateway** | ✅ Full (v1.0) | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ✅ Yes | Recommended for new setups |
| **NGINX Kubernetes Gateway** | ✅ Full (v1.0) | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ✅ Yes | Enterprise support available |
| **Traefik 3.x** | ✅ Full (v1.0) | ⭐⭐⭐ | ⭐⭐⭐⭐ | ✅ Yes | Upgrade path from RKE2 Traefik |
| **Istio** | ✅ Full | ⭐⭐ | ⭐⭐⭐⭐⭐ | ✅ Yes | Overkill for just Gateway API |
| **Kong** | ✅ Full | ⭐⭐⭐ | ⭐⭐⭐⭐ | ✅ Yes | Rich plugin ecosystem |

## Installation Steps for Envoy Gateway (Recommended)

### Prerequisites

```bash
# Ensure Gateway API CRDs are installed
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# Note: Envoy Gateway v1.6.1 supports Gateway API v1.0.0

# Verify CRDs
kubectl get crd | grep gateway
```

### Step 1: Install Gateway API CRDs (if not already installed)

```bash
# Install Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# Verify CRDs are installed
kubectl get crd | grep gateway
```

### Step 2: Install Envoy Gateway

```bash
# Set context for manager cluster
export KUBECONFIG=~/.kube/rancher-manager.yaml

# Install Envoy Gateway using official manifest
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.6.1/install.yaml

# Wait for deployment to be ready
kubectl wait --for=condition=available deployment/envoy-gateway -n envoy-gateway-system --timeout=5m

# Verify installation
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclass
```

### Step 2: Create GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-eg
```

Apply it:
```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-eg
EOF
```

### Step 3: Create a Gateway

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg-gateway
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF
```

### Step 4: Configure Service Type

```bash
# Get the Gateway service
kubectl get svc -n envoy-gateway-system

# If using LoadBalancer, update service type (or use NodePort for bare metal)
kubectl patch svc eg-envoy-gateway -n envoy-gateway-system \
  -p '{"spec":{"type":"NodePort"}}'

# Get the NodePort
kubectl get svc eg-envoy-gateway -n envoy-gateway-system
```

### Step 5: Create HTTPRoute (Example)

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: default
spec:
  parentRefs:
  - name: eg-gateway
  hostnames:
  - "httpbin.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin
      port: 80
EOF
```

## Integration with Rancher

### Multi-Cluster Setup

Gateway API works seamlessly with Rancher's multi-cluster management:

```bash
# Install on each cluster via Rancher UI or kubectl
# Manager cluster
kubectl --kubeconfig ~/.kube/rancher-manager.yaml \
  apply -f envoy-gateway-install.yaml

# NPRD Apps cluster
kubectl --kubeconfig ~/.kube/nprd-apps.yaml \
  apply -f envoy-gateway-install.yaml

# PRD Apps cluster (if exists)
kubectl --kubeconfig ~/.kube/prd-apps.yaml \
  apply -f envoy-gateway-install.yaml
```

### Fleet GitOps Integration

You can deploy Gateway API resources via Fleet:

```yaml
# fleet.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: gateway-api-configs
  namespace: fleet-default
spec:
  repo: https://github.com/your-org/gateway-configs
  branch: main
  paths:
  - gateway-api/*
  targets:
  - clusterSelector:
      matchLabels:
        env: nprd
```

## TLS/SSL Configuration

### Using cert-manager (Already Installed)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: production-gateway
spec:
  gatewayClassName: eg
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-tls
        kind: Secret
        group: ""
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
spec:
  secretName: wildcard-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "*.example.com"
  - "example.com"
```

## DNS Configuration

Update your DNS records to point to the Gateway service:

```bash
# Get the external IP or NodePort
kubectl get svc eg-envoy-gateway -n envoy-gateway-system

# For NodePort (bare metal), point DNS to node IPs
# For LoadBalancer, point DNS to LoadBalancer IP
```

Update DNS records (similar to your existing setup in `DNS_CONFIGURATION.md`):

```
gateway.example.com    A    192.168.1.100
gateway.example.com    A    192.168.1.101
gateway.example.com    A    192.168.1.102
```

## Migration from Ingress to Gateway API

### Key Differences

1. **Namespaced vs Cluster-scoped**: Gateway is namespace-scoped, GatewayClass is cluster-scoped
2. **Role-based**: Gateway API supports admin vs developer roles
3. **Multi-protocol**: Supports HTTP, HTTPS, TCP, UDP, TLS
4. **Cross-namespace**: Routes can reference Gateways in other namespaces (with proper configuration)

### Example Migration

**Before (Ingress):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
spec:
  ingressClassName: traefik
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
```

**After (Gateway API):**
```yaml
# Gateway (created once, referenced by routes)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: app-gateway
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: app.example.com

---
# HTTPRoute (created per application)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
spec:
  parentRefs:
  - name: app-gateway
  hostnames:
  - app.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: app-service
      port: 80
```

## Troubleshooting

### Gateway Not Ready

```bash
# Check Gateway status
kubectl describe gateway eg-gateway

# Check GatewayClass
kubectl get gatewayclass

# Check Envoy Gateway pods
kubectl get pods -n envoy-gateway-system
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway
```

### Routes Not Working

```bash
# Check HTTPRoute status
kubectl describe httproute httpbin-route

# Check backend services
kubectl get svc

# Check Envoy proxy logs
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy
```

### DNS Issues

```bash
# Test Gateway service connectivity
curl -H "Host: httpbin.example.com" http://GATEWAY_IP:PORT

# Check service endpoints
kubectl get endpoints
```

## Best Practices

1. **Use separate Gateways per environment** (nprd, prd)
2. **Leverage Gateway API's role separation**: Infrastructure team manages Gateways, developers manage HTTPRoutes
3. **Use Gateway API's policy attachment** for security policies
4. **Monitor Gateway metrics** (Envoy exposes Prometheus metrics)
5. **Use TLS termination at Gateway** for better security
6. **Implement proper namespace isolation** using `allowedRoutes`

## Next Steps

1. ✅ Install Gateway API CRDs
2. ✅ Choose and install Gateway API controller (Envoy Gateway recommended)
3. ✅ Create GatewayClass
4. ✅ Create first Gateway
5. ✅ Migrate one application from Ingress to Gateway API
6. ✅ Set up TLS/SSL with cert-manager
7. ✅ Configure monitoring/observability
8. ✅ Migrate remaining applications gradually

## References

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [NGINX Kubernetes Gateway](https://github.com/nginxinc/nginx-kubernetes-gateway)
- [Traefik Gateway API Support](https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/)
