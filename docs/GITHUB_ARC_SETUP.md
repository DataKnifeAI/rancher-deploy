# GitHub Actions Runner Controller (ARC) Setup Guide

**Last Updated**: January 2025

Complete guide to setting up the **Official GitHub-Supported Actions Runner Controller (ARC)** with Rancher Fleet on downstream clusters.

## Overview

The GitHub Actions Runner Controller (ARC) enables you to run self-hosted GitHub Actions runners in your Kubernetes clusters. This guide covers:

1. **Installation** - Installing the ARC controller and CRDs
2. **Secret Configuration** - Setting up GitHub authentication
3. **Fleet Integration** - Managing runners via Rancher Fleet
4. **Troubleshooting** - Common issues and solutions

## Table of Contents

1. [ARC Version Information](#arc-version-information)
2. [Installation](#installation)
3. [Secret Configuration](#secret-configuration)
4. [Fleet Integration](#fleet-integration)
5. [Troubleshooting](#troubleshooting)
6. [Verification](#verification)

## ARC Version Information

### Official ARC (gha-runner-scale-set) ✅ **CURRENT**

We use the **Official GitHub-Supported ARC**:

- **Maintainer**: GitHub (official support)
- **CRDs**: `AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`
- **API Group**: `actions.github.com/v1alpha1`
- **Chart**: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
- **Release Name**: `gha-runner-scale-set-controller`
- **Documentation**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller

**Pros**:
- ✅ Officially supported by GitHub
- ✅ Better runner group support
- ✅ More efficient scaling (ephemeral runners)
- ✅ Better resource utilization
- ✅ Active development by GitHub

### Legacy ARC (actions-runner-controller) - **DEPRECATED**

- **Maintainer**: Community (summerwind)
- **CRDs**: `RunnerDeployment`, `HorizontalRunnerAutoscaler`, `RunnerSet`
- **API Group**: `actions.summerwind.dev/v1alpha1`
- **Status**: Still maintained but not officially supported by GitHub

**Note**: If migrating from legacy, update Fleet resources from `RunnerDeployment` to `AutoscalingRunnerSet`.

## Installation

### Prerequisites

- Kubernetes cluster (RKE2) with kubectl access
- Helm 3.x installed
- GitHub organization or repository access
- GitHub App or Personal Access Token (PAT)

### Method 1: Install via Script (Recommended)

```bash
# Install on nprd-apps cluster
./scripts/install-github-arc.sh nprd-apps

# Install on prd-apps cluster
./scripts/install-github-arc.sh prd-apps

# Install on poc-apps cluster
./scripts/install-github-arc.sh poc-apps
```

### Method 2: Install via Helm (Manual)

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/nprd-apps.yaml

# Install official ARC controller
helm install gha-runner-scale-set-controller \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace actions-runner-system \
  --create-namespace \
  --wait

# Verify installation
kubectl get pods -n actions-runner-system
kubectl get crd | grep -E "autoscalingrunnerset|ephemeralrunner"
```

### Method 3: Install via Terraform (Automated)

The ARC controller can be automatically installed via Terraform. Check `terraform/main.tf` for:
- `null_resource.deploy_arc_nprd_apps`
- `null_resource.deploy_arc_prd_apps`
- `null_resource.deploy_arc_poc_apps`

The controller is automatically installed when you run `terraform apply`.

### Verify CRDs Installed

The CRDs are installed immediately when Helm installs the chart. Verify:

```bash
kubectl get crd | grep -E "autoscalingrunnerset|ephemeralrunner"

# Should show:
# - autoscalingrunnersets.actions.github.com
# - ephemeralrunnersets.actions.github.com
# - ephemeralrunners.actions.github.com
```

**Important**: Fleet can validate runner resources as soon as CRDs exist, even if the controller pod is still starting.

## Secret Configuration

The ARC controller requires GitHub authentication at **two levels**:

1. **Controller Secret** (`controller-manager` in `actions-runner-system`) - For the controller to manage runner scale sets
2. **Runner Scale Set Secret** (referenced by `AutoscalingRunnerSet` via `githubConfigSecret`) - For the runner scale set to authenticate with GitHub

### Helper Scripts

We provide helper scripts to automate secret creation:

#### Interactive Setup Script (Recommended)

```bash
# Interactive guide through GitHub App creation and secret setup
./scripts/setup-github-app-arc.sh
```

This script will:
- Guide you through creating the GitHub App via web interface
- Collect App ID, Installation ID, and private key path
- Automatically create Kubernetes secrets for your cluster(s)

#### Direct Secret Creation Script

```bash
# Create secrets directly (if you already have app details)
./scripts/create-github-app-secrets.sh \
  -c nprd-apps \
  -i YOUR_APP_ID \
  -n YOUR_INSTALLATION_ID \
  -k /path/to/private-key.pem
```

#### List Existing Apps

```bash
# View GitHub Apps (opens web interface)
./scripts/list-github-apps.sh
```

### Authentication Methods

ARC supports two authentication methods for both secrets:

#### Method 1: GitHub Personal Access Token (PAT) - For Testing

**Use for**: Development/testing environments, quick setup

**Pros**:
- Simple setup (just one token)
- Quick to configure

**Cons**:
- Less secure (broad permissions)
- User account dependency
- Can expire if account is inactive
- Not recommended for production

##### Controller Secret (PAT)

```bash
# For nprd-apps
kubectl --kubeconfig ~/.kube/nprd-apps.yaml create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_token="YOUR_GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# For prd-apps
kubectl --kubeconfig ~/.kube/prd-apps.yaml create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_token="YOUR_GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart deployments
kubectl --kubeconfig ~/.kube/nprd-apps.yaml rollout restart deployment gha-runner-scale-set-controller -n actions-runner-system
```

##### Runner Scale Set Secret (PAT)

```bash
# For nprd-apps - Create secret in the runner namespace (e.g., managed-cicd)
kubectl --kubeconfig ~/.kube/nprd-apps.yaml create secret generic github-app-secret \
  -n managed-cicd \
  --from-literal=github_token="YOUR_GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Note**: The `AutoscalingRunnerSet` resource must reference this secret:
```yaml
spec:
  githubConfigSecret: github-app-secret  # Name of the secret
```

#### Method 2: GitHub App Authentication - **Recommended for Production** ✅

**Use for**: Production environments, organizations, security-sensitive setups

**Pros**:
- ✅ More secure (scoped permissions)
- ✅ No user account dependency
- ✅ Fine-grained permissions
- ✅ Better audit trail
- ✅ Official GitHub recommendation
- ✅ Better runner group support

**Cons**:
- Slightly more complex setup
- Requires GitHub App creation

##### Step 1: Create a GitHub App

1. Go to your organization → **Settings** → **Developer settings** → **GitHub Apps**
2. **Check existing apps** (to avoid name conflicts): https://github.com/organizations/YOUR_ORG/settings/apps
3. Click **New GitHub App**
4. Configure the app:
   - **Name**: Must be unique across all GitHub. Try:
     - `arc-runner-controller-{org-name}` (e.g., `arc-runner-controller-dataknifeai`)
     - `arc-runner-controller-{date}` (e.g., `arc-runner-controller-20260109`)
     - `arc-runner-controller-{org}-{env}` (e.g., `arc-runner-controller-dataknifeai-nprd`)
   - **Homepage URL**: Your organization URL (e.g., `https://github.com/DataKnifeAI`)
   - **Webhook**: Unchecked (not required for ARC)
   - **Permissions**:
     - **Repository Permissions**:
       - `Actions`: **Read & Write**
       - `Metadata`: **Read-only**
     - **Organization Permissions**:
       - `Self-hosted runners`: **Read & Write**
   - **Where can this GitHub App be installed?**: **Only on this account**
5. Click **Create GitHub App**
6. **Note the App ID** (visible on the app page, under the app name)
7. Generate and download the private key:
   - Scroll down to **Private keys**
   - Click **Generate a private key**
   - Save the downloaded `.pem` file securely (you can only download it once!)
8. Install the app on your organization:
   - Click **Install App** (in sidebar or top of app page)
   - Select your organization (e.g., **DataKnifeAI**)
   - Choose installation permissions (All repositories recommended for ARC)
   - Click **Install**
   - **Note the Installation ID** (visible in the URL: `/installations/<INSTALLATION_ID>`)

##### Step 2: Create Controller Secret (GitHub App)

```bash
# For nprd-apps
kubectl --kubeconfig ~/.kube/nprd-apps.yaml create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_app_id="YOUR_APP_ID" \
  --from-literal=github_app_installation_id="YOUR_INSTALLATION_ID" \
  --from-literal=github_app_private_key="$(cat path/to/private-key.pem)" \
  --dry-run=client -o yaml | kubectl apply -f -

# For prd-apps
kubectl --kubeconfig ~/.kube/prd-apps.yaml create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_app_id="YOUR_APP_ID" \
  --from-literal=github_app_installation_id="YOUR_INSTALLATION_ID" \
  --from-literal=github_app_private_key="$(cat path/to/private-key.pem)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart deployments
kubectl --kubeconfig ~/.kube/nprd-apps.yaml rollout restart deployment gha-runner-scale-set-controller -n actions-runner-system
kubectl --kubeconfig ~/.kube/prd-apps.yaml rollout restart deployment gha-runner-scale-set-controller -n actions-runner-system
```

##### Step 3: Create Runner Scale Set Secret (GitHub App)

**Important**: This secret is referenced by the `AutoscalingRunnerSet` resource via `spec.githubConfigSecret`.

```bash
# For nprd-apps - Create secret in the runner namespace (e.g., managed-cicd)
kubectl --kubeconfig ~/.kube/nprd-apps.yaml create secret generic github-app-secret \
  -n managed-cicd \
  --from-literal=github_app_id="YOUR_APP_ID" \
  --from-literal=github_app_installation_id="YOUR_INSTALLATION_ID" \
  --from-literal=github_app_private_key="$(cat path/to/private-key.pem)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Note**: The `AutoscalingRunnerSet` resource must reference this secret:
```yaml
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: nprd-autoscale-runners
  namespace: managed-cicd
spec:
  githubConfigUrl: "https://github.com/DataKnifeAI"  # Organization URL
  githubConfigSecret: github-app-secret  # Name of the secret created above
  runnerLabels:
    - self-hosted
  # ... rest of configuration
```

**Same App or Different?**: You can use the same GitHub App for both secrets, or create separate apps for controller and runners. Using the same app is simpler and recommended for most setups.

### Secret Structure

#### Controller Secret (`controller-manager` in `actions-runner-system`)

Can contain:
- `github_token` - Personal Access Token (optional)
- `github_app_id` - GitHub App ID (optional)
- `github_app_installation_id` - Installation ID (optional)
- `github_app_private_key` - PEM-encoded private key (optional)

**Note**: Only ONE authentication method should be used:
- Use either `github_token` OR `github_app_*` fields
- Don't mix both methods

#### Runner Scale Set Secret (`githubConfigSecret` in runner namespace)

**For GitHub App** (recommended):
- `github_app_id` - GitHub App ID (required)
- `github_app_installation_id` - Installation ID (required)
- `github_app_private_key` - PEM-encoded private key (required)

**For Personal Access Token**:
- `github_token` - Personal Access Token (required)

**Secret Name**: The secret name is specified in the `AutoscalingRunnerSet` resource via `spec.githubConfigSecret` (e.g., `github-app-secret`).

**Namespace**: The secret must be in the same namespace as the `AutoscalingRunnerSet` resource.

## Fleet Integration

### The Fleet Dependency Issue (Resolved)

**Problem**: Fleet processes all resources together and validates them. When Fleet tried to apply `AutoscalingRunnerSet` resources, the CRDs didn't exist yet, causing the bundle to fail.

**Solution**: Install the ARC controller (which includes CRDs) **before** Fleet processes runner resources.

### Recommended Setup

#### Step 1: Install Controller First (One-time)

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

#### Step 2: Configure Fleet GitRepo

Once CRDs are installed, Fleet can now validate runner resources:

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

**Note**: Controller is installed via Helm/Terraform, not managed by Fleet. Fleet only manages the runner scale set resources.

#### Step 3: Fleet Manifests Structure

Your GitOps repository should have:

```
gitops/
└── arc-runners/     # Runner resources (managed by Fleet)
    └── autoscaling-runner-set.yaml  # AutoscalingRunnerSet resource
```

### Runner Resources Example

#### Official ARC (AutoscalingRunnerSet) ✅ **CURRENT**

```yaml
apiVersion: actions.github.com/v1alpha1
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

### Fleet Dependency Configuration (Advanced)

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

## Troubleshooting

### Controller Pod Stuck in CrashLoopBackOff

**Symptom**: Controller pods show `CrashLoopBackOff` with authentication errors

**Solution**: Update secret with valid GitHub credentials (see [Secret Configuration](#secret-configuration) section)

```bash
# Check controller logs
kubectl logs -n actions-runner-system -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50

# Check secret exists
kubectl get secret controller-manager -n actions-runner-system
```

### Fleet Bundle Fails with CRD Not Found

**Symptom**: Fleet reports validation errors for `AutoscalingRunnerSet`

**Solution**: Install official ARC controller first:
```bash
./scripts/install-github-arc.sh nprd-apps
```

**Note**: CRDs are installed immediately when Helm installs the chart, even if the controller pod takes time to start. Fleet only needs CRDs to validate resources.

### CRD Version Mismatch

**Symptom**: Fleet resources use legacy CRDs (`RunnerDeployment`) but official controller is installed (`AutoscalingRunnerSet`)

**Solution**:
1. Check which CRDs exist: `kubectl get crd | grep -E "autoscalingrunnerset|runnerdeployment"`
2. Update Fleet resources to use `AutoscalingRunnerSet` (official version)
3. Or migrate from legacy: See migration section in official docs

### Pods Stuck in ContainerCreating

**Symptom**: Pods show `0/2 ContainerCreating` with "secret controller-manager not found"

**Solution**: Create the secret (even if empty):
```bash
kubectl create secret generic controller-manager -n actions-runner-system \
  --from-literal=github_token=""
```

### Checking Secrets

#### Controller Secret

```bash
# View controller secret (note: values are base64 encoded)
kubectl get secret controller-manager -n actions-runner-system -o yaml

# Decode values
kubectl get secret controller-manager -n actions-runner-system -o jsonpath='{.data.github_token}' | base64 -d
kubectl get secret controller-manager -n actions-runner-system -o jsonpath='{.data.github_app_id}' | base64 -d
```

#### Runner Scale Set Secret

```bash
# View runner secret (replace 'managed-cicd' with your namespace)
kubectl get secret github-app-secret -n managed-cicd -o yaml

# Decode values
kubectl get secret github-app-secret -n managed-cicd -o jsonpath='{.data.github_app_id}' | base64 -d
kubectl get secret github-app-secret -n managed-cicd -o jsonpath='{.data.github_app_installation_id}' | base64 -d
```

## Verification

### Verification Checklist

- [ ] ARC controller installed and running
- [ ] CRDs verified: `kubectl get crd | grep runner`
- [ ] Controller secret created: `kubectl get secret controller-manager -n actions-runner-system`
- [ ] Runner scale set secret created (in runner namespace)
- [ ] Fleet GitRepo configured
- [ ] Fleet paths point to runner resources only (not controller)
- [ ] Fleet bundle status is Active (not stuck in validation)
- [ ] Runner resources applied successfully
- [ ] Runner pods created: `kubectl get pods -n <runner-namespace>`

### Check Controller Status

```bash
# Check pod status
kubectl get pods -n actions-runner-system

# Check controller logs (official version)
kubectl logs -n actions-runner-system -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50
```

Expected: Pods should show `Running` status and logs should show no authentication errors.

### Check Fleet Status

```bash
# Check Fleet bundles
kubectl get bundle -A | grep runner

# Check Fleet bundle status
kubectl describe bundle <fleet-bundle-name> -n fleet-default

# Check Fleet GitRepo
kubectl get gitrepo -A
```

## Important Notes

### Fleet Validation (Already Working)

✅ **Fleet can validate `AutoscalingRunnerSet` resources right now (official version)**  
✅ **CRDs are installed on both clusters**  
✅ **Controller doesn't need to be running for Fleet validation**  
✅ **Using official GitHub-supported ARC** (`actions.github.com/v1alpha1`)

The controller only needs to be running when:
- Actually managing and scaling runners
- Processing runner lifecycle events
- Communicating with GitHub API

### Secret Volume Mount

The deployment expects a secret named `controller-manager` in the `actions-runner-system` namespace. If the secret doesn't exist, pods will fail to start due to volume mount errors.

Even with an empty secret, the CRDs are installed and Fleet can validate resources. However, the controller will crash until proper GitHub credentials are provided.

## Related Documentation

- [Official GitHub ARC Documentation](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller)
- [Quickstart Guide](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart)
- [Deploy Runner Scale Sets](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets)
- [About ARC](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller)

## Summary

✅ **Install controller first** - Official ARC controller (with CRDs) must be installed before Fleet processes runner resources  
✅ **Separate controller from runners** - Controller via Helm/Terraform, runners via Fleet  
✅ **Use official version** - Official GitHub-supported ARC (`AutoscalingRunnerSet`, not legacy `RunnerDeployment`)  
✅ **Verify CRD compatibility** - Ensure Fleet resources use `AutoscalingRunnerSet` (actions.github.com/v1alpha1)  
✅ **Fleet paths** - Only include runner resources, not controller manifests  
✅ **Use GitHub App** - Recommended for production environments

This ensures Fleet can validate runner resources because CRDs exist when Fleet processes them, and the controller can manage runners once secrets are configured.
