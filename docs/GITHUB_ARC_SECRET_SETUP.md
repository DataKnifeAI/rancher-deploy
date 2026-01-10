# GitHub ARC Controller - Secret Configuration

**Last Updated**: January 9, 2026

## Overview

The **Official GitHub Actions Runner Controller (ARC)** requires GitHub authentication at **two levels**:

1. **Controller Secret** (`controller-manager` in `actions-runner-system`) - For the controller to manage runner scale sets
2. **Runner Scale Set Secret** (referenced by `AutoscalingRunnerSet` via `githubConfigSecret`) - For the runner scale set to authenticate with GitHub

This document explains how to configure both secrets for the official GitHub-supported version.

## Current Status

✅ **CRDs Installed**: Required CRDs (`AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`) are installed on both clusters  
⚠️  **Controller Status**: Controller pods will restart until GitHub credentials are configured  
✅ **Fleet Ready**: Fleet can validate runner resources because CRDs exist  
✅ **Version**: Official GitHub-supported ARC (not legacy community version)

## Secret Configuration

### Secret 1: Controller Secret (`controller-manager`)

The controller requires authentication to create and manage runner scale sets. This secret must be in the `actions-runner-system` namespace.

### Secret 2: Runner Scale Set Secret (`githubConfigSecret`)

Each `AutoscalingRunnerSet` resource references a secret via `spec.githubConfigSecret`. This secret must be in the same namespace as the `AutoscalingRunnerSet` resource (e.g., `managed-cicd`).

**Recommendation**: Use **GitHub App** for both secrets in production environments.

## Helper Scripts

We provide helper scripts to automate secret creation:

### Interactive Setup Script (Recommended)

```bash
# Interactive guide through GitHub App creation and secret setup
./scripts/setup-github-app-arc.sh
```

This script will:
- Guide you through creating the GitHub App via web interface
- Collect App ID, Installation ID, and private key path
- Automatically create Kubernetes secrets for your cluster(s)

### Direct Secret Creation Script

```bash
# Create secrets directly (if you already have app details)
./scripts/create-github-app-secrets.sh \
  -c nprd-apps \
  -i YOUR_APP_ID \
  -n YOUR_INSTALLATION_ID \
  -k /path/to/private-key.pem
```

### List Existing Apps

```bash
# View GitHub Apps (opens web interface)
./scripts/list-github-apps.sh
```

## Authentication Methods

ARC supports two authentication methods for both secrets:

### Method 1: GitHub Personal Access Token (PAT) - Recommended for Testing

**Use for**: Development/testing environments, quick setup

**Pros**:
- Simple setup (just one token)
- Quick to configure

**Cons**:
- Less secure (broad permissions)
- User account dependency
- Can expire if account is inactive
- Not recommended for production

#### Controller Secret (PAT)

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
```

#### Runner Scale Set Secret (PAT)

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

### Method 2: GitHub App Authentication - **Recommended for Production** ✅

1. **Create a GitHub Personal Access Token**:
   - Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Create a token with `repo` scope
   - Copy the token value

2. **Update the Secret**:

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
kubectl --kubeconfig ~/.kube/prd-apps.yaml rollout restart deployment gha-runner-scale-set-controller -n actions-runner-system
```

### Method 2: GitHub App Authentication - **Recommended for Production** ✅

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

#### Step 1: Create a GitHub App

1. Go to your organization → **Settings** → **Developer settings** → **GitHub Apps**
2. **Check existing apps** (to avoid name conflicts): https://github.com/organizations/YOUR_ORG/settings/apps
3. Click **New GitHub App**
4. Configure the app:
   - **Name**: Must be unique across all GitHub. Try:
     - `arc-runner-controller-{org-name}` (e.g., `arc-runner-controller-dataknifeai`)
     - `arc-runner-controller-{date}` (e.g., `arc-runner-controller-20260109`)
     - `arc-runner-controller-{org}-{env}` (e.g., `arc-runner-controller-dataknifeai-nprd`)
     - ⚠️ **If name is taken**: Try adding date suffix, organization name, or environment
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
   - ⚠️ **If you see "Name already taken"**: Choose a different name (see suggestions above)
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

#### Step 2: Create Controller Secret (GitHub App)

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

#### Step 3: Create Runner Scale Set Secret (GitHub App)

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

## Verification

After updating the secret:

```bash
# Check pod status
kubectl --kubeconfig ~/.kube/nprd-apps.yaml get pods -n actions-runner-system
kubectl --kubeconfig ~/.kube/prd-apps.yaml get pods -n actions-runner-system

# Check controller logs (official version)
kubectl --kubeconfig ~/.kube/nprd-apps.yaml logs -n actions-runner-system -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=20
```

Expected: Pods should show `2/2 Running` status and logs should show no authentication errors.

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

## Troubleshooting

### Pods Stuck in ContainerCreating

**Symptom**: Pods show `0/2 ContainerCreating` with "secret controller-manager not found"

**Solution**: Create the secret (even if empty):
```bash
kubectl create secret generic controller-manager -n actions-runner-system \
  --from-literal=github_token=""
```

### Pods in CrashLoopBackOff

**Symptom**: Pods show `1/2 CrashLoopBackOff` with authentication errors

**Solution**: Update secret with valid GitHub credentials (see Method 1 or 2 above)

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

## Secret Structure

### Controller Secret (`controller-manager` in `actions-runner-system`)

Can contain:
- `github_token` - Personal Access Token (optional)
- `github_app_id` - GitHub App ID (optional)
- `github_app_installation_id` - Installation ID (optional)
- `github_app_private_key` - PEM-encoded private key (optional)

**Note**: Only ONE authentication method should be used:
- Use either `github_token` OR `github_app_*` fields
- Don't mix both methods

### Runner Scale Set Secret (`githubConfigSecret` in runner namespace)

**For GitHub App** (recommended):
- `github_app_id` - GitHub App ID (required)
- `github_app_installation_id` - Installation ID (required)
- `github_app_private_key` - PEM-encoded private key (required)

**For Personal Access Token**:
- `github_token` - Personal Access Token (required)

**Secret Name**: The secret name is specified in the `AutoscalingRunnerSet` resource via `spec.githubConfigSecret` (e.g., `github-app-secret`).

**Namespace**: The secret must be in the same namespace as the `AutoscalingRunnerSet` resource.

### Helm Values

Current Helm configuration:
```yaml
authSecret:
  enabled: false  # Secret creation is disabled, manual secret management
syncPeriod: 10m
```

## Summary

✅ **Fleet Dependency Issue**: Resolved - CRDs are installed  
✅ **Fleet Validation**: Working - Fleet can validate runner resources  
⚠️  **Controller Authentication**: Needs GitHub credentials to run fully  
📝 **Next Step**: Configure GitHub credentials when ready to deploy actual runners

The controller can remain in a restarting state until credentials are configured. Fleet doesn't require the controller to be running to validate resources.
