# Documentation Index

Complete documentation for the Rancher Deploy project.

## Core Documentation

### Deployment Guides
- **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)** - Complete deployment walkthrough
- **[CLOUD_IMAGE_SETUP.md](CLOUD_IMAGE_SETUP.md)** - Cloud image provisioning and VM configuration
- **[MODULES_AND_AUTOMATION.md](MODULES_AND_AUTOMATION.md)** - Terraform modules, variables, and automation details

### Rancher Configuration
- **[RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md)** - How API tokens are created automatically
- **[RANCHER_DOWNSTREAM_MANAGEMENT.md](RANCHER_DOWNSTREAM_MANAGEMENT.md)** - Automatic downstream cluster registration

### Network & DNS
- **[DNS_CONFIGURATION_GUIDE.md](DNS_CONFIGURATION_GUIDE.md)** - Complete DNS configuration guide
- **[DNS_CONFIGURATION.md](DNS_CONFIGURATION.md)** - DNS records required for Rancher

### Storage
- **[TRUENAS_STORAGE_SETUP.md](TRUENAS_STORAGE_SETUP.md)** - Complete TrueNAS storage setup guide (consolidated)
- **[TRUENAS_SECRETS_MANAGEMENT.md](TRUENAS_SECRETS_MANAGEMENT.md)** - Secrets management workflow
- **[STORAGE_CLASS_DEFAULT.md](STORAGE_CLASS_DEFAULT.md)** - Storage class default configuration

### Database Management
- **[CLOUDNATIVEPG_SETUP.md](CLOUDNATIVEPG_SETUP.md)** - CloudNativePG operator setup and PostgreSQL cluster management

### Infrastructure
- **[API_TOKEN_AND_PERMISSIONS.md](API_TOKEN_AND_PERMISSIONS.md)** - Proxmox API token creation and permissions
- **[PROXMOX_AGENT_SETUP.md](PROXMOX_AGENT_SETUP.md)** - Proxmox guest agent configuration

### Troubleshooting
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Common issues and solutions

## Reference Documentation

### TrueNAS Permissions
- **[TRUENAS_MINIMUM_PERMISSIONS.md](TRUENAS_MINIMUM_PERMISSIONS.md)** - Minimum permissions reference
- **[DEMOCRATIC_CSI_TRUENAS_SETUP.md](DEMOCRATIC_CSI_TRUENAS_SETUP.md)** - General democratic-csi setup

## Quick Links

### Getting Started
1. [Deployment Guide](DEPLOYMENT_GUIDE.md) - Start here for first-time deployment
2. [API Token Setup](API_TOKEN_AND_PERMISSIONS.md) - Required before deployment
3. [DNS Configuration](DNS_CONFIGURATION.md) - Required DNS records

### Storage Setup
1. [TrueNAS Storage Setup](TRUENAS_STORAGE_SETUP.md) - Complete storage guide
2. [Secrets Management](TRUENAS_SECRETS_MANAGEMENT.md) - How secrets are managed

### Database Management
1. [CloudNativePG Setup](CLOUDNATIVEPG_SETUP.md) - PostgreSQL cluster management with CloudNativePG

### Troubleshooting
1. [Troubleshooting Guide](TROUBLESHOOTING.md) - Common issues
2. [Rancher Downstream Management](RANCHER_DOWNSTREAM_MANAGEMENT.md) - Cluster registration issues

## Documentation Structure

```
docs/
├── Core Documentation/
│   ├── Deployment guides
│   ├── Rancher configuration
│   ├── Network & DNS
│   └── Storage
├── Reference Documentation/
│   ├── TrueNAS (legacy - see TRUENAS_STORAGE_SETUP.md)
│   └── Analysis & Planning
└── Troubleshooting
```

## Contributing

When adding new documentation:
1. Place in `docs/` folder
2. Update this README.md
3. Update main [README.md](../README.md) if it's a core feature
4. Use clear, descriptive filenames
5. Include examples and troubleshooting sections
