# GitHub ARC Controller - Secret Configuration

**Last Updated**: January 9, 2026

## Overview

The **Official GitHub Actions Runner Controller (ARC)** requires GitHub authentication to manage runners. This document explains how to configure the required secrets for the official GitHub-supported version.

## Current Status

✅ **CRDs Installed**: Required CRDs (`AutoscalingRunnerSet`, `EphemeralRunnerSet`, `EphemeralRunner`) are installed on both clusters  
⚠️  **Controller Status**: Controller pods will restart until GitHub credentials are configured  
✅ **Fleet Ready**: Fleet can validate runner resources because CRDs exist  
✅ **Version**: Official GitHub-supported ARC (not legacy community version)

## Authentication Methods

ARC supports two authentication methods:

### Method 1: GitHub Personal Access Token (PAT) - Recommended for Testing

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

### Method 2: GitHub App Authentication - Recommended for Production

1. **Create a GitHub App**:
   - Go to your organization → Settings → Developer settings → GitHub Apps
   - Create a new GitHub App
   - Note the App ID and Installation ID
   - Generate and download a private key

2. **Update the Secret**:

```bash
# For nprd-apps
kubectl --kubeconfig ~/.kube/nprd-apps.yaml create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_app_id="YOUR_APP_ID" \
  --from-literal=github_app_installation_id="YOUR_INSTALLATION_ID" \
  --from-literal=github_app_private_key="$(cat path/to/private-key.pem)" \
  --dry-run=client -o yaml | kubectl apply -f -

# For prd-apps (same process)
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
✅ **Using official GitHub-supported ARC** (`actions.github.com/v1beta1`)

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

### Checking Secret

```bash
# View secret (note: values are base64 encoded)
kubectl get secret controller-manager -n actions-runner-system -o yaml

# Decode values
kubectl get secret controller-manager -n actions-runner-system -o jsonpath='{.data.github_token}' | base64 -d
```

## Current Configuration

### Secret Structure

The `controller-manager` secret can contain:
- `github_token` - Personal Access Token (optional)
- `github_app_id` - GitHub App ID (optional)
- `github_app_installation_id` - Installation ID (optional)
- `github_app_private_key` - PEM-encoded private key (optional)

**Note**: Only ONE authentication method should be used:
- Use either `github_token` OR `github_app_*` fields
- Don't mix both methods

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
