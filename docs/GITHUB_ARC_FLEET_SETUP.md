# GitHub Actions Runner Controller (ARC) with Fleet Setup

**Last Updated**: January 9, 2026

This guide covers setting up **Official GitHub-Supported Actions Runner Controller (ARC)** with Rancher Fleet, resolving the CRD dependency ordering issue.

## The Problem

Fleet processes all resources together and validates them. When Fleet tries to apply `AutoscalingRunnerSet` resources, the CRDs don't exist yet, causing the bundle to fail.

**Root Cause**: Fleet bundles all resources and validates them together. Custom resources fail validation because CRDs don't exist, preventing the HelmChart from being created.

## Solution: Install CRDs First

The ARC controller (which includes CRDs) must be installed **before** Fleet processes runner resources. This can be done via:

1. **Helm installation** (recommended) - Install controller via Helm
2. **Terraform bootstrap** - Install controller as part of cluster setup
3. **Fleet dependency** - Use Fleet dependencies to ensure ordering

## ARC Version - Official GitHub Version (Current)

We use the **Official GitHub-Supported ARC**:

### Official ARC (gha-runner-scale-set) ✅ **CURRENT**
- **Maintainer**: GitHub (official support)
- **CRDs**: `AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`
- **API Group**: `actions.github.com/v1beta1`
- **Chart**: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
- **Release Name**: `gha-runner-scale-set-controller`
- **Documentation**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller
- **Pros**: 
  - ✅ Officially supported by GitHub
  - ✅ Better runner group support
  - ✅ More efficient scaling (ephemeral runners)
  - ✅ Better resource utilization
  - ✅ Active development by GitHub

### Legacy ARC (actions-runner-controller) - **DEPRECATED**
- **Maintainer**: Community (summerwind)
- **CRDs**: `RunnerDeployment`, `HorizontalRunnerAutoscaler`, `RunnerSet`
- **API Group**: `actions.summerwind.dev/v1alpha1`
- **Chart**: `actions-runner-controller/actions-runner-controller`
- **Status**: Still maintained but not officially supported by GitHub

**Note**: If migrating from legacy, update Fleet resources from `RunnerDeployment` to `AutoscalingRunnerSet`.

## Installation Methods

### Method 1: Install Controller via Helm (Recommended)

Install the official GitHub ARC controller (includes CRDs) before Fleet processes resources:

```bash
# Using the installation script (recommended)
./scripts/install-github-arc.sh nprd-apps

# Or install manually using OCI chart
helm install gha-runner-scale-set-controller \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace actions-runner-system \
  --create-namespace \
  --wait
```

**Note**: The CRDs (`AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`) are installed immediately when Helm installs the chart. The controller pod may take time to start, but Fleet only needs the CRDs to validate resources.

**Official Documentation**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller

**Then** let Fleet manage the runner resources.

### Method 2: Install via Terraform Bootstrap (Already Configured)

Terraform automatically installs the official ARC controller. The installation is configured in `terraform/main.tf`:

- **NPRD Apps Cluster**: `null_resource.deploy_arc_nprd_apps`
- **PRD Apps Cluster**: `null_resource.deploy_arc_prd_apps`

Both use the official OCI chart: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`

The controller is automatically installed when you run `terraform apply`.

### Method 3: Fleet Dependency (Advanced)

Use Fleet's dependency mechanism to ensure controller is installed first:

```yaml
# fleet-controller.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: arc-controller
spec:
  repo: https://github.com/your-org/gitops
  paths:
    - arc-controller
  targets:
    - clusterName: nprd-apps

---
# fleet-runners.yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: arc-runners
spec:
  repo: https://github.com/your-org/gitops
  paths:
    - arc-runners
  dependsOn:
    - name: arc-controller
  targets:
    - clusterName: nprd-apps
```

## Recommended Setup

### Step 1: Install Controller (One-time)

The controller is automatically installed via Terraform when you deploy clusters. If you need to install manually:

```bash
# Using the installation script (recommended)
./scripts/install-github-arc.sh nprd-apps

# Or install manually using OCI chart (official GitHub version)
helm install gha-runner-scale-set-controller \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace actions-runner-system \
  --create-namespace \
  --wait
```

**Important**: The CRDs (`AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`) are installed as soon as Helm installs the chart. Fleet can validate resources immediately, even if the controller pod is still starting.

### Step 2: Verify CRDs

```bash
kubectl get crd | grep -E "autoscalingrunnerset|ephemeralrunner"

# Official ARC should show:
# - autoscalingrunnersets.actions.github.com
# - ephemeralrunnersets.actions.github.com
# - ephemeralrunners.actions.github.com
```

### Step 3: Configure Fleet

Once CRDs are installed, Fleet can now validate runner resources:

1. **Configure Fleet GitRepo** to point to your runner manifests
2. **Fleet paths** should only include runner resources (not controller)
3. **Cluster targeting** should target nprd-apps cluster

### Step 4: Fleet Manifests Structure

Your GitOps repository should have:

```
gitops/
└── arc-runners/     # Runner resources (managed by Fleet)
    └── autoscaling-runner-set.yaml  # AutoscalingRunnerSet resource
```

**Note**: Controller is installed via Helm/Terraform, not managed by Fleet. Fleet only manages the runner scale set resources.

## Troubleshooting

### Fleet Bundle Fails with CRD Not Found

**Symptom**: Fleet reports validation errors for `AutoscalingRunnerSet`

**Solution**: Install official ARC controller first:
```bash
./scripts/install-github-arc.sh nprd-apps
```

### CRD Version Mismatch

**Symptom**: Fleet resources use legacy CRDs (`RunnerDeployment`) but official controller is installed (`AutoscalingRunnerSet`)

**Solution**: 
1. Check which CRDs exist: `kubectl get crd | grep -E "autoscalingrunnerset|runnerdeployment"`
2. Update Fleet resources to use `AutoscalingRunnerSet` (official version)
3. Or migrate from legacy: See migration section below

### Controller Not Running

**Check controller status**:
```bash
kubectl get pods -n actions-runner-system
kubectl logs -n actions-runner-system -l app.kubernetes.io/name=gha-runner-scale-set-controller
```

## Fleet GitRepo Configuration Example

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: github-arc-runners
  namespace: fleet-default
spec:
  repo: https://github.com/your-org/gitops-repo
  paths:
    - arc-runners  # Only runner resources, not controller
  branch: main
  targets:
    - clusterName: nprd-apps
```

## Runner Resources Example

### Official ARC (AutoscalingRunnerSet) ✅ **CURRENT**

```yaml
apiVersion: actions.github.com/v1beta1
kind: AutoscalingRunnerSet
metadata:
  name: example-runner-scale-set
  namespace: arc-runners
spec:
  githubConfigUrl: "https://github.com/your-org/your-repo"
  githubConfigSecret: github-config-secret
  maxRunners: 10
  minRunners: 0
  runnerLabels:
    - self-hosted
  template:
    spec:
      containers:
      - image: ghcr.io/actions/actions-runner:latest
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
```

**Note**: For complete configuration options, see: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets

### Legacy ARC (RunnerDeployment) - Migration Reference

If migrating from legacy, old resources looked like:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
# ... legacy configuration ...
```

**Migration**: Convert to `AutoscalingRunnerSet` (see official docs above).

## Verification Checklist

- [ ] ARC controller installed and running
- [ ] CRDs verified: `kubectl get crd | grep runner`
- [ ] Fleet GitRepo configured
- [ ] Fleet paths point to runner resources only (not controller)
- [ ] Fleet bundle status is Active (not stuck in validation)
- [ ] Runner resources applied successfully
- [ ] Runner pods created: `kubectl get pods -n arc-runners`

## Summary

✅ **Install controller first** - Official ARC controller (with CRDs) must be installed before Fleet processes runner resources  
✅ **Separate controller from runners** - Controller via Helm/Terraform, runners via Fleet  
✅ **Use official version** - Official GitHub-supported ARC (`AutoscalingRunnerSet`, not legacy `RunnerDeployment`)  
✅ **Verify CRD compatibility** - Ensure Fleet resources use `AutoscalingRunnerSet` (actions.github.com/v1beta1)  
✅ **Fleet paths** - Only include runner resources, not controller manifests  

This ensures Fleet can validate runner resources because CRDs exist when Fleet processes them.

## Official GitHub Documentation

- **Quickstart**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart
- **Deploy Runner Scale Sets**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets
- **About ARC**: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller
