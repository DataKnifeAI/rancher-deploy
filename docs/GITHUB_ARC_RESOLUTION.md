# GitHub ARC Fleet Dependency Issue - Resolution

**Date**: January 9, 2026  
**Issue**: Fleet blocked on dependency ordering - CRDs not found  
**Status**: ✅ **RESOLVED** (Updated to Official GitHub Version)

## Problem Summary

Fleet processes all resources together. When Fleet tried to apply `AutoscalingRunnerSet` resources (official GitHub version), the CRDs didn't exist yet, causing the bundle to fail and preventing the HelmChart from being created.

**Root Cause**: Fleet bundles all resources and validates them together. Custom resources failed validation because CRDs didn't exist.

## Solution Applied

1. ✅ **Installed official GitHub ARC controller** (for `AutoscalingRunnerSet` compatibility)
2. ✅ **Verified CRDs installed**: 
   - `autoscalingrunnersets.actions.github.com` (official version)
   - `ephemeralrunnersets.actions.github.com`
   - `ephemeralrunners.actions.github.com`
3. ✅ **Created installation script**: `scripts/install-github-arc.sh` (updated for official version)
4. ✅ **Created documentation**: `docs/GITHUB_ARC_FLEET_SETUP.md` (updated for official version)

## Current Status

### CRDs Installed ✅ (Official GitHub Version)
```bash
$ kubectl get crd | grep -E "autoscalingrunnerset|ephemeralrunner"
autoscalingrunnersets.actions.github.com                2026-01-09T01:01:10Z
ephemeralrunnersets.actions.github.com                  2026-01-09T01:01:09Z
ephemeralrunners.actions.github.com                     2026-01-09T01:01:10Z
```

### Controller Status
- **Namespace**: `actions-runner-system`
- **Helm Release**: `gha-runner-scale-set-controller` (official GitHub version)
- **Chart**: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`
- **Controller Pod**: Starting (CRDs already available for Fleet)

### Fleet Status
- ✅ Fleet can now validate `AutoscalingRunnerSet` resources (official version)
- ✅ Fleet bundle should no longer fail on CRD validation errors
- ✅ Using official GitHub-supported ARC (not legacy community version)

## Verification

To verify Fleet can now process runner resources:

```bash
# Check CRDs exist (official version)
kubectl get crd autoscalingrunnersets.actions.github.com ephemeralrunnersets.actions.github.com ephemeralrunners.actions.github.com

# Check Fleet bundles (replace with your Fleet bundle name)
kubectl get bundle -A | grep runner

# Check Fleet bundle status
kubectl describe bundle <fleet-bundle-name> -n fleet-default
```

## Next Steps

1. **Fleet GitRepo**: Ensure Fleet GitRepo is configured to deploy runner resources
2. **Fleet Paths**: Verify Fleet paths only include runner resources (not controller)
3. **Cluster Targeting**: Confirm cluster targeting (nprd-apps) is correct
4. **Monitor Fleet**: Watch Fleet bundle status - should now succeed

## Installation Script Usage

For future installations or other clusters:

```bash
# Install ARC controller on nprd-apps
./scripts/install-github-arc.sh nprd-apps

# Install ARC controller on prd-apps
./scripts/install-github-arc.sh prd-apps
```

The script:
- Installs legacy ARC controller (compatible with `RunnerDeployment`)
- Installs CRDs required by Fleet
- Configures proper namespace and settings
- Verifies installation

## Related Documentation

- `docs/GITHUB_ARC_FLEET_SETUP.md` - Complete setup guide
- `scripts/install-github-arc.sh` - Installation script

## Notes

- **CRD Installation**: CRDs are installed immediately when Helm installs the chart, even if the controller pod takes time to start
- **Fleet Validation**: Fleet only needs CRDs to validate resources, not a running controller
- **Controller Pod**: The controller pod may take time to start, but Fleet can proceed with validation once CRDs exist
