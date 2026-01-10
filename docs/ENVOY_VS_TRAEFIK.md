# Envoy vs Traefik: Comprehensive Comparison

**Last Updated**: January 2025

## Overview

Both **Envoy** and **Traefik** are popular reverse proxies and ingress controllers for Kubernetes, but they have different architectures, use cases, and design philosophies. This guide helps you understand the differences and choose the right one for your RKE2 + Rancher setup.

## Quick Summary

| Aspect | Envoy | Traefik |
|--------|-------|---------|
| **Type** | Service proxy (data plane) | Reverse proxy & load balancer |
| **Language** | C++ | Go |
| **Architecture** | Sidecar + Gateway | Standalone reverse proxy |
| **Configuration** | Declarative (YAML/JSON) | Dynamic auto-discovery |
| **Built-in UI** | ❌ No (uses external tools) | ✅ Yes (built-in dashboard) |
| **Ease of Use** | ⚠️ More complex | ✅ Easier, developer-friendly |
| **Performance** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐⭐ Very Good |
| **Observability** | ⭐⭐⭐⭐⭐ Rich metrics/logs | ⭐⭐⭐⭐ Good |
| **Gateway API** | ✅ Envoy Gateway (purpose-built) | ✅ Traefik 3.x |
| **RKE2 Default** | ❌ No | ✅ Yes (bundled) |

## Architecture Comparison

### Envoy

**Design Philosophy**: High-performance service proxy designed for microservices

```
┌─────────────────────────────────────┐
│   Envoy Proxy (Data Plane)          │
│   - C++ core (high performance)     │
│   - L4/L7 proxy                     │
│   - Service mesh ready              │
│   - Sidecar or Gateway mode         │
└─────────────────────────────────────┘
           ↕️
┌─────────────────────────────────────┐
│   Control Plane (separate)          │
│   - Envoy Gateway (for Gateway API) │
│   - Istio (for service mesh)        │
│   - Consul Connect                  │
└─────────────────────────────────────┘
```

**Key Characteristics:**
- **Data plane + Control plane separation**: Envoy is the proxy, but needs a control plane to configure it
- **Service mesh native**: Originally designed for service mesh architectures (Istio, Consul)
- **Sidecar pattern**: Can run as sidecar alongside each service
- **Gateway mode**: Can run as edge gateway (Envoy Gateway)

### Traefik

**Design Philosophy**: Auto-configuring reverse proxy with developer-friendly UX

```
┌─────────────────────────────────────┐
│   Traefik (All-in-One)              │
│   - Go application                  │
│   - Built-in configuration engine   │
│   - Built-in dashboard              │
│   - Auto-discovery                  │
│   - No separate control plane       │
└─────────────────────────────────────┘
```

**Key Characteristics:**
- **Self-contained**: Everything in one binary
- **Auto-discovery**: Automatically discovers services, routes, certificates
- **Developer-friendly**: Built-in dashboard, simpler configuration
- **Standalone**: Works independently without separate control plane

## Detailed Feature Comparison

### 1. Performance

#### Envoy ⭐⭐⭐⭐⭐
- **C++ core**: Lower latency, higher throughput
- **Non-blocking I/O**: Handles thousands of concurrent connections
- **Better for high-traffic**: Enterprise-grade performance
- **Resource efficient**: Optimized for cloud-native workloads

**Benchmark Example:**
```
Requests/sec: ~100,000+
Latency (p99): < 1ms
Memory: ~50-100MB base + per-connection overhead
```

#### Traefik ⭐⭐⭐⭐
- **Go implementation**: Good performance, but typically slower than Envoy
- **Sufficient for most workloads**: Excellent for small to medium traffic
- **Lower resource usage**: Simpler architecture means less overhead

**Benchmark Example:**
```
Requests/sec: ~50,000-80,000
Latency (p99): 1-2ms
Memory: ~30-60MB base
```

**Verdict**: Envoy wins for high-performance, high-traffic scenarios. Traefik is sufficient for most applications.

### 2. Configuration & Ease of Use

#### Envoy ⚠️ More Complex
```yaml
# Envoy Gateway API (simpler, recommended)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg-gateway
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
```

```yaml
# Raw Envoy config (complex)
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 10000
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            # ... more config
```

**Pros:**
- ✅ Very powerful and flexible
- ✅ Fine-grained control
- ✅ Gateway API simplifies configuration significantly

**Cons:**
- ❌ Steeper learning curve
- ❌ More verbose configuration
- ❌ Requires understanding of Envoy concepts

#### Traefik ✅ Easier
```yaml
# Traefik Ingress (very simple)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
spec:
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

**Pros:**
- ✅ Very simple configuration
- ✅ Auto-discovery (finds services automatically)
- ✅ Built-in dashboard for visualization
- ✅ Less boilerplate

**Cons:**
- ⚠️ Less fine-grained control than Envoy
- ⚠️ Some advanced features require annotations

**Verdict**: Traefik wins for ease of use. Envoy is more powerful but requires more expertise.

### 3. Observability & Monitoring

#### Envoy ⭐⭐⭐⭐⭐
```bash
# Rich metrics endpoint
curl http://localhost:9901/stats/prometheus

# Metrics include:
# - Request/response counts
# - Latency percentiles (p50, p99, p99.9)
# - Circuit breaker states
# - Health check status
# - Upstream connection pools
# - TLS handshake metrics
```

**Features:**
- ✅ **Extensive metrics**: 100+ built-in metrics
- ✅ **Access logs**: Detailed request/response logging
- ✅ **Distributed tracing**: OpenTracing/OpenTelemetry support
- ✅ **Admin interface**: Runtime configuration inspection
- ✅ **WebAssembly filters**: Custom observability plugins

#### Traefik ⭐⭐⭐⭐
```bash
# Traefik dashboard
# Access at: http://traefik-ip:8080

# Metrics endpoint
curl http://traefik-ip:8080/metrics
```

**Features:**
- ✅ **Built-in dashboard**: Visual UI for routes, services, health
- ✅ **Prometheus metrics**: Good metric coverage
- ✅ **Access logs**: Configurable logging
- ✅ **Less detailed**: Fewer metrics than Envoy

**Verdict**: Envoy wins for deep observability. Traefik wins for visual debugging with its dashboard.

### 4. Gateway API Support

#### Envoy Gateway ✅
```yaml
# Purpose-built for Gateway API
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-eg
```

**Status:**
- ✅ **Official Gateway API implementation**: Built specifically for Gateway API
- ✅ **Full v1.0 support**: Complete Gateway API feature set
- ✅ **Lightweight**: Minimal overhead, just Gateway API support
- ✅ **Recommended by Gateway API SIG**: Official implementation

#### Traefik 3.x ✅
```yaml
# Traefik with Gateway API support
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
```

**Status:**
- ✅ **Full v1.0 support**: Complete Gateway API implementation
- ✅ **Backward compatible**: Still supports traditional Ingress
- ⚠️ **RKE2 bundled version**: May not have Gateway API support (check version)
- ⚠️ **Heavier**: Includes Ingress support + Gateway API

**Verdict**: Envoy Gateway is purpose-built for Gateway API. Traefik adds Gateway API as a feature.

### 5. Service Mesh Integration

#### Envoy ✅ Native
- **Istio**: Uses Envoy as data plane
- **Consul Connect**: Uses Envoy as proxy
- **Linkerd**: Uses Rust proxy, but similar architecture
- **Built for service mesh**: Originally designed for this use case

#### Traefik ❌ Not Designed For
- **Standalone reverse proxy**: Not designed for service mesh
- **No sidecar support**: Runs as edge gateway, not sidecar
- **No mTLS**: Doesn't provide service-to-service encryption

**Verdict**: Envoy if you need service mesh. Traefik if you only need edge gateway.

### 6. TLS/SSL Management

#### Envoy
- ✅ **Manual certificate management**: You configure certificates
- ✅ **SNI support**: Full Server Name Indication support
- ✅ **mTLS**: Mutual TLS for service-to-service communication
- ✅ **Certificate rotation**: Supports dynamic certificate updates
- ⚠️ **No built-in ACME**: Need external tool (cert-manager) for Let's Encrypt

#### Traefik
- ✅ **Auto certificate management**: Can automatically get Let's Encrypt certs
- ✅ **ACME support**: Built-in Let's Encrypt integration
- ✅ **Certificate storage**: Multiple backends (file, Kubernetes secrets, etc.)
- ✅ **Automatic renewal**: Handles certificate renewal automatically
- ⚠️ **No mTLS**: Edge-only TLS, not for service mesh

**Verdict**: Traefik wins for automatic certificate management. Envoy wins for advanced TLS features.

### 7. Extensibility

#### Envoy
- ✅ **WebAssembly filters**: Write custom filters in WASM
- ✅ **Lua scripting**: Lua scripts for request/response manipulation
- ✅ **Plugin architecture**: Extensible filter chain
- ✅ **C++ extensions**: Write custom extensions in C++

#### Traefik
- ✅ **Middleware plugins**: Custom middleware in Go
- ✅ **Plugin system**: Traefik plugins for extended functionality
- ⚠️ **Less extensible**: Fewer extension points than Envoy

**Verdict**: Envoy wins for extensibility, especially with WebAssembly support.

## Use Case Recommendations

### Choose Envoy Gateway When:

1. ✅ **You want Gateway API**: Purpose-built for Gateway API
2. ✅ **High-performance requirements**: Need maximum throughput/low latency
3. ✅ **Service mesh plans**: Planning to implement Istio/Consul
4. ✅ **Advanced observability**: Need detailed metrics and tracing
5. ✅ **Multi-cluster complexity**: Complex multi-cluster routing
6. ✅ **Microservices architecture**: Many services with complex routing

### Choose Traefik When:

1. ✅ **Ease of use**: Want simplicity and developer-friendly UX
2. ✅ **Already using RKE2**: Traefik is bundled and working
3. ✅ **Traditional Ingress**: Still using Ingress API (can migrate later)
4. ✅ **Auto-certificates**: Want automatic Let's Encrypt certificates
5. ✅ **Small to medium traffic**: Performance is sufficient
6. ✅ **Quick setup**: Need something working fast with minimal config
7. ✅ **Visual debugging**: Want built-in dashboard

### Use Both (Recommended for Your Setup) ✅

**Best Practice for RKE2 + Rancher:**

```
┌─────────────────────────────────────────────┐
│   Existing Traefik (RKE2 default)           │
│   - Handles traditional Ingress             │
│   - Legacy applications                     │
│   - Rancher UI (if using Ingress)           │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│   Envoy Gateway (New)                       │
│   - Gateway API implementations             │
│   - New applications                        │
│   - Modern routing requirements             │
└─────────────────────────────────────────────┘
```

**Why Both:**
- ✅ Traefik continues handling existing Ingress resources
- ✅ Envoy Gateway handles new Gateway API resources
- ✅ No disruption to existing applications
- ✅ Gradual migration path
- ✅ Each tool used for its strength

## Performance Benchmarks (Approximate)

### Throughput (Requests/Second)

| Scenario | Envoy | Traefik |
|----------|-------|---------|
| Simple HTTP routing | ~100,000 | ~60,000 |
| HTTPS with TLS termination | ~80,000 | ~50,000 |
| Complex routing rules | ~70,000 | ~45,000 |
| With rate limiting | ~60,000 | ~40,000 |

### Latency (p99)

| Scenario | Envoy | Traefik |
|----------|-------|---------|
| Simple routing | < 1ms | 1-2ms |
| Complex routing | 1-2ms | 2-3ms |
| TLS termination | 2-3ms | 3-4ms |

### Resource Usage

| Metric | Envoy | Traefik |
|--------|-------|---------|
| Memory (idle) | ~50-100MB | ~30-60MB |
| Memory (10k req/s) | ~200-300MB | ~150-200MB |
| CPU (10k req/s) | ~0.5-1 core | ~0.7-1.2 cores |

## Migration Path: Traefik to Envoy Gateway

### Option 1: Keep Both (Recommended) ✅

```bash
# Keep existing Traefik for Ingress
# Deploy Envoy Gateway for Gateway API
helm install eg envoy-gateway/envoy-gateway \
  --namespace envoy-gateway-system \
  --create-namespace

# Use Traefik for existing apps
# Use Envoy Gateway for new Gateway API apps
```

### Option 2: Migrate to Envoy Gateway Only

```bash
# 1. Install Envoy Gateway
helm install eg envoy-gateway/envoy-gateway

# 2. Migrate Ingress resources to Gateway API
# (See migration guide in GATEWAY_API_SETUP.md)

# 3. Disable Traefik (if RKE2 allows)
# Or leave it disabled/unused
```

### Option 3: Upgrade Traefik to Support Gateway API

```bash
# Check RKE2 Traefik version
kubectl get deployment traefik -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'

# If version < 3.0, install Traefik separately with Gateway API support
helm install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --set providers.kubernetesGateway.enabled=true \
  --set providers.kubernetesIngress.enabled=true
```

## Decision Matrix for Your Setup

### Current Situation (RKE2 + Rancher)

| Factor | Recommendation | Reason |
|--------|----------------|--------|
| **Existing Traefik** | ✅ Keep it | Already working, handles Rancher |
| **Gateway API** | ✅ Use Envoy Gateway | Purpose-built, recommended |
| **Migration** | ✅ Gradual | Migrate new apps to Gateway API |
| **Legacy Ingress** | ✅ Keep Traefik | Continue using for existing apps |
| **Future-proof** | ✅ Envoy Gateway | Gateway API is the future |

### Recommended Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    RKE2 Cluster                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────┐   │
│  │   Traefik (Existing) │  │  Envoy Gateway (New) │   │
│  │   - Ingress API      │  │  - Gateway API       │   │
│  │   - Rancher UI       │  │  - New apps          │   │
│  │   - Legacy apps      │  │  - Modern routing    │   │
│  └──────────────────────┘  └──────────────────────┘   │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │           Your Applications                      │  │
│  │  - Use Traefik via Ingress (existing)           │  │
│  │  - Use Envoy Gateway via Gateway API (new)      │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Summary

### Envoy Gateway Advantages
- ✅ Purpose-built for Gateway API (official implementation)
- ✅ Superior performance and observability
- ✅ Future-proof (Gateway API is the standard)
- ✅ Better for complex routing scenarios
- ✅ Can run alongside Traefik (no conflict)

### Traefik Advantages
- ✅ Already installed with RKE2
- ✅ Easier to use and configure
- ✅ Built-in dashboard
- ✅ Auto-certificate management
- ✅ Works well for simple to medium complexity

### Best Practice for Your Setup
**Use both**: Keep Traefik for existing Ingress-based applications, deploy Envoy Gateway for new Gateway API-based applications. This gives you:
- ✅ Zero disruption to existing setup
- ✅ Modern Gateway API capabilities
- ✅ Gradual migration path
- ✅ Each tool used for its strengths

## References

- [Envoy Documentation](https://www.envoyproxy.io/docs)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)
