# GitOps vs Terraform: Management Strategy

**Last Updated**: January 8, 2026

This document outlines the recommended management strategy for different components in the Rancher deployment.

## Management Strategy Overview

### Infrastructure Layer (Terraform)
**Managed by**: Terraform

- ✅ VM provisioning (Proxmox)
- ✅ Kubernetes cluster setup (RKE2)
- ✅ Network configuration
- ✅ Storage infrastructure (TrueNAS setup)
- ✅ Platform operators (democratic-csi, CloudNativePG)
- ✅ Rancher installation

**Why Terraform?**
- Infrastructure is relatively static
- Changes require careful planning
- State management is critical
- Part of cluster bootstrap process

### Application Layer (GitOps)
**Recommended for**: Applications and application-level controllers

- ✅ CI/CD Runners (GitLab Runner, GitHub Actions Runner Controller)
- ✅ Application deployments
- ✅ Configuration management
- ✅ Helm chart deployments
- ✅ Custom resource definitions (CRDs) for applications

**Why GitOps?**
- Applications change frequently
- Configuration drift detection
- Continuous reconciliation
- Better for application lifecycle
- Easier to update and rollback

## Recommended Approach for CI/CD Runners

### Option 1: Rancher Apps (Recommended - Easiest)

Since you already have Rancher, use Rancher's built-in app management:

**Pros:**
- ✅ No additional tooling required
- ✅ UI-based management
- ✅ Integrated with existing Rancher setup
- ✅ Helm chart support
- ✅ Easy updates via Rancher UI

**Implementation:**
1. Install runners via Rancher UI:
   - Cluster Management → nprd-apps → Apps & Marketplace
   - Install GitLab Runner or GitHub Actions Runner Controller
   - Configure values through UI

2. Or use Rancher CLI:
   ```bash
   rancher apps install gitlab-runner gitlab/gitlab-runner \
     --namespace gitlab-runner \
     --set runnerRegistrationToken="<TOKEN>"
   ```

**When to use:**
- Quick setup and management
- Small team
- Prefer UI over code
- Don't need advanced GitOps features

### Option 2: GitOps with ArgoCD (Recommended - Most Flexible)

Install ArgoCD and manage runners via GitOps:

**Pros:**
- ✅ Declarative configuration in Git
- ✅ Automatic drift detection
- ✅ Continuous reconciliation
- ✅ Multi-cluster support
- ✅ Rollback capabilities
- ✅ Audit trail

**Implementation:**
1. Install ArgoCD:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Create Application manifests:
   ```yaml
   # gitops/apps/gitlab-runner.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: gitlab-runner
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://charts.gitlab.io/
       chart: gitlab-runner
       targetRevision: latest
       helm:
         values: |
           runnerRegistrationToken: <TOKEN>
     destination:
       server: https://kubernetes.default.svc
       namespace: gitlab-runner
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

**When to use:**
- Need advanced GitOps features
- Multiple environments
- Want Git-based workflow
- Team comfortable with GitOps

### Option 3: Keep Terraform (Current Approach)

Continue managing runners via Terraform:

**Pros:**
- ✅ Single tool for everything
- ✅ Already implemented
- ✅ Consistent with current pattern

**Cons:**
- ❌ Less flexible for frequent updates
- ❌ No automatic drift detection
- ❌ Requires Terraform apply for changes
- ❌ Mixes infrastructure and applications

**When to use:**
- Simple setup
- Runners rarely change
- Prefer single tool
- Don't need GitOps features

## Comparison Table

| Feature | Terraform | Rancher Apps | ArgoCD (GitOps) |
|---------|-----------|--------------|-----------------|
| Setup Complexity | Medium | Low | High |
| Update Frequency | Manual apply | UI/CLI | Automatic |
| Drift Detection | No | No | Yes |
| Rollback | Manual | UI/CLI | Automatic |
| Multi-cluster | Yes | Yes | Yes |
| Git-based | Yes | No | Yes |
| UI Available | No | Yes | Yes |
| Learning Curve | Medium | Low | High |

## Recommendation

### For CI/CD Runners: **Rancher Apps** (Short-term) or **ArgoCD** (Long-term)

**Short-term (Now):**
- Use Rancher Apps for quick setup
- Leverage existing Rancher infrastructure
- Easy to manage via UI
- Can migrate to GitOps later

**Long-term (Future):**
- Install ArgoCD for GitOps
- Move runners to GitOps workflow
- Better for scaling and automation
- Industry best practice

### Migration Path

1. **Phase 1**: Install runners via Rancher Apps (immediate)
2. **Phase 2**: Install ArgoCD on manager cluster
3. **Phase 3**: Migrate runners to ArgoCD Application manifests
4. **Phase 4**: Remove Terraform resources for runners

## Implementation Guide

### Using Rancher Apps

1. **Access Rancher UI**:
   - Navigate to Cluster Management → nprd-apps → Apps & Marketplace

2. **Install GitLab Runner**:
   - Search for "gitlab-runner"
   - Click Install
   - Configure values:
     ```yaml
     runnerRegistrationToken: <YOUR_TOKEN>
     rbac:
       create: true
     ```

3. **Install GitHub Actions Runner Controller**:
   - Search for "actions-runner-controller"
   - Click Install
   - Configure authentication after installation

### Using ArgoCD (Future)

1. **Install ArgoCD**:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. **Create GitOps repository structure**:
   ```
   gitops/
   ├── apps/
   │   ├── gitlab-runner.yaml
   │   └── github-actions-runner-controller.yaml
   └── values/
       ├── gitlab-runner-values.yaml
       └── arc-values.yaml
   ```

3. **Create Application manifests** (see example above)

## Current Terraform Resources

The current Terraform resources for runners can be:
- **Kept** for initial bootstrap (install once, then manage via GitOps)
- **Removed** if using Rancher Apps or ArgoCD exclusively
- **Modified** to only create namespaces, then let GitOps manage the rest

## Best Practice: Hybrid Approach

**Recommended Pattern:**

1. **Terraform**: Bootstrap infrastructure and platform operators
   - Create namespaces
   - Install platform-level operators (CSI, CNPG)
   - Set up storage classes

2. **GitOps/Rancher**: Manage applications
   - CI/CD runners
   - Application deployments
   - Configuration updates

3. **Terraform**: Keep for infrastructure changes
   - Cluster scaling
   - Storage configuration
   - Network changes

## Summary

- ✅ **Infrastructure**: Terraform (VMs, clusters, storage)
- ✅ **Platform Operators**: Terraform (CSI, CNPG)
- ✅ **CI/CD Runners**: Rancher Apps (now) or ArgoCD (future)
- ✅ **Applications**: GitOps (ArgoCD) or Rancher Apps

This separation provides:
- Clear ownership boundaries
- Appropriate tooling for each layer
- Flexibility for future changes
- Industry best practices
