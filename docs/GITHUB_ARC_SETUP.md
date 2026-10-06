# GitHub Actions Runner Controller (ARC): retired

ARC was removed from all apps clusters on 2026-10-05. No runner scale sets were ever wired up
(zero `AutoscalingRunnerSet`, `EphemeralRunnerSet` or legacy `RunnerDeployment` objects on any
cluster), so the controller, its CRDs, the `actions-runner-system` namespace, the Terraform
`deploy_arc_*` resources and the GitHub App helper scripts were deleted. CI runs on the GitLab
runner (`gitops-tools` `gitlab-runner` overlay, nprd-apps).

To bring ARC back, install the current `gha-runner-scale-set-controller` chart together with a
`gha-runner-scale-set` per runner group (GitHub supports only the latest ARC release). The old
setup guide and scripts are in the git history before this change.
