# Changelog

All notable changes to Rancher Deploy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **cert-manager Module**: New Terraform module for automated cert-manager deployment across downstream clusters
  - Automatic detection and cleanup of pre-existing unmanaged cert-manager installations
  - Comprehensive resource cleanup (CRDs, ClusterRoles, Roles, WebhookConfigurations)
  - Version-based triggers for automatic upgrades when version changes
  - Support for nprd-apps, prd-apps, and poc-apps clusters
- **cert-manager Version Management**: Automatic resource recreation when `cert_manager_version` changes in terraform.tfvars
  - Triggers on version, cluster_name, kubeconfig_path, and namespace changes
  - Eliminates need for manual resource tainting

### Changed
- **cert-manager Version**: Upgraded from v1.13.0 (EOL) to v1.19.2 (latest stable)
  - v1.13.0 reached end-of-life on June 5, 2024
  - v1.19.2 provides security updates, bug fixes, and improved Kubernetes compatibility
- **cert-manager Deployment**: Now managed via dedicated Terraform module instead of inline scripts
  - Improved error handling and resource cleanup
  - Better support for upgrading from unmanaged installations

### Fixed
- **cert-manager Installation Issues**: Resolved Helm ownership metadata conflicts
  - Automatic cleanup of unmanaged CRDs, ClusterRoles, ClusterRoleBindings
  - Automatic cleanup of namespaced Roles and RoleBindings in kube-system
  - Automatic cleanup of MutatingWebhookConfiguration and ValidatingWebhookConfiguration
  - Proper waiting periods for resource deletion before reinstallation

## [1.1.0] - 2026-01-01

### Added
- **Automatic Logging Infrastructure**: New `apply.sh` script with automatic `TF_LOG=debug` logging
- **Timestamped Log Files**: Deploy logs saved to `terraform/terraform-<timestamp>.log`
- **Documentation Consolidation**: Streamlined from 6 docs to 4 focused guides
  - DEPLOYMENT_GUIDE.md - Complete deployment walkthrough with logging
  - TROUBLESHOOTING.md - Issue resolution and diagnostics
  - MODULES_AND_AUTOMATION.md - Terraform modules and RKE2/Rancher automation
  - CLOUD_IMAGE_SETUP.md - Ubuntu 24.04 provisioning details
- **RKE2 Troubleshooting Guide**: Complete section on version management and common issues
- **Root-level Documentation**: CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md

### Changed
- **RKE2 Version Management**: Updated from non-existent "latest" to specific versions (v1.34.3+rke2r1)
- **RKE2 Installation Script**: Improved from piped curl to download+chmod+execute pattern
- **Environment Variable Handling**: Fixed `sudo -E bash -c` pattern for proper expansion
- **Cloud-Init Provisioning**: Added `wait_for_cloud_init` to ensure networking ready before RKE2
- **Provider References**: Removed deprecated custom providers (dataknife/pve, telmate/proxmox)
- **README.md**: Updated with RKE2 version emphasis, logging instructions, consolidated doc references

### Fixed
- **RKE2 404 Errors**: Resolved "latest" version download failures by using specific release tags
- **Terraform State Caching**: Cleaned state files and validated fresh deployments
- **SSH Host Key Issues**: Added `cleanup_known_hosts` provisioner for cleaner deployments
- **RKE2 Script Execution**: Fixed edge cases with piped curl installation method
- **Documentation Overlaps**: Removed duplicate content across 6 documentation files (537 lines cleaned)

### Deprecated
- Custom Proxmox providers (now using bpg/proxmox v0.90.0 exclusively)
- "latest" RKE2 version references (must use specific versions)

## [1.0.0] - 2025-12-20

### Added
- Initial release of Rancher Deploy project
- Terraform configuration for Proxmox VE
- RKE2 Kubernetes cluster deployment
- Rancher management cluster setup
- Non-production apps cluster configuration
- Cloud-init integration for Ubuntu 24.04 LTS
- Module-based Terraform structure
  - proxmox_vm module for VM creation
  - rke2_cluster module for Kubernetes setup
  - rancher_cluster module for Rancher deployment
- Comprehensive documentation suite
  - DEPLOYMENT_GUIDE.md
  - TERRAFORM_VARIABLES.md
  - TROUBLESHOOTING.md
  - CLOUD_IMAGE_SETUP.md
- Example configurations and templates
- GitIgnore patterns for sensitive data

### Features
- ✅ Full automation from VMs to Rancher
- ✅ Cloud image provisioning (Ubuntu 24.04 LTS)
- ✅ bpg/proxmox v0.90.0 provider with reliable task polling
- ✅ RKE2 Kubernetes v1.34.3+rke2r1
- ✅ High availability 3-node clusters
- ✅ Cloud-init networking, DNS, hostnames
- ✅ Secure API token authentication
- ✅ Comprehensive troubleshooting guides

---

For detailed changes, see the [Git commit history](https://github.com/surrealwolf/rancher-deploy/commits/main).
