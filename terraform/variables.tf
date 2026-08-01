variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_api_user" {
  description = "Proxmox API user"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Disable TLS verification for Proxmox API"
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Proxmox node to create VMs on"
  type        = string
}

variable "vm_cpu_type" {
  description = "CPU type for VMs (e.g., qemu64, host, kvm64)"
  type        = string
  default     = "qemu64"
}

variable "clusters" {
  description = "Configuration for Rancher clusters"
  type = map(object({
    name                = string
    node_count          = number # Server nodes (control plane + etcd)
    worker_count        = number # Worker nodes (optional, default: 0)
    cpu_cores           = number # Server CPU cores
    memory_mb           = number # Server memory
    disk_size_gb        = number # Server disk
    worker_cpu_cores    = number # Worker CPU cores (optional, defaults to server value)
    worker_memory_mb    = number # Worker memory (optional, defaults to server value)
    worker_disk_size_gb = number # Worker disk (optional, defaults to server value)
    domain              = string
    ip_subnet           = string
    ip_start_octet      = number # Starting IP octet (e.g., 100 for 192.168.1.100)
    gateway             = string
    dns_servers         = list(string)
    storage             = string
    vlan_id             = number # VLAN ID for network interface
  }))
}

variable "vm_id_start_manager" {
  description = "Starting VM ID for manager cluster (e.g., 401 for VMs 401, 402, 403)"
  type        = number
  default     = 401
}

variable "vm_id_start_nprd_apps" {
  description = "Starting VM ID for nprd-apps cluster (e.g., 410 for VMs 410, 411, 412)"
  type        = number
  default     = 410
}

variable "vm_id_start_prd_apps" {
  description = "Starting VM ID for prd-apps cluster (e.g., 420 for VMs 420, 421, 422)"
  type        = number
  default     = 420
}

variable "vm_id_start_poc_apps" {
  description = "Starting VM ID for poc-apps cluster (e.g., 430 for VMs 430, 431, 432)"
  type        = number
  default     = 430
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.13.0"
}

variable "ubuntu_cloud_image_url" {
  description = "Ubuntu cloud image URL (24.04 noble)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "rancher_version" {
  description = "Rancher version to install"
  type        = string
  default     = "v2.7.7"
}


variable "rke2_version" {
  description = "RKE2 version pin for new node bootstrap (INSTALL_RKE2_VERSION). Changing this alone does not upgrade existing nodes."
  type        = string
  default     = "v1.34.3+rke2r1"
}



variable "rancher_password" {
  description = "Rancher admin password"
  type        = string
  sensitive   = true
}

variable "rancher_hostname" {
  description = "Rancher manager hostname"
  type        = string
}

variable "install_rancher" {
  description = "Whether to install Rancher on the manager cluster"
  type        = bool
  default     = false
}

variable "ssh_private_key" {
  description = "Path to SSH private key for VM access"
  type        = string
}

variable "rancher_api_token" {
  description = "Rancher API token for cluster management (obtain from Rancher: Account → API Tokens)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "register_downstream_cluster" {
  description = "Whether to automatically register all downstream clusters (nprd-apps, prd-apps, poc-apps) with Rancher Manager"
  type        = bool
  default     = true
}

variable "manager_cluster_hostname" {
  description = "Hostname for manager cluster TLS SANs (used in RKE2 certificate generation)"
  type        = string
  default     = "manager.example.com"
}

variable "manager_cluster_primary_ip" {
  description = "Primary IP for manager cluster TLS SANs"
  type        = string
  default     = "192.168.1.100"
}

variable "nprd_apps_cluster_hostname" {
  description = "Hostname for nprd-apps cluster TLS SANs (used in RKE2 certificate generation)"
  type        = string
  default     = "nprd-apps.example.com"
}

variable "nprd_apps_cluster_primary_ip" {
  description = "Primary IP for nprd-apps cluster TLS SANs"
  type        = string
  default     = "192.168.1.110"
}

variable "manager_cluster_aliases" {
  description = "Additional hostname aliases for manager cluster TLS SANs (e.g., rancher.example.com)"
  type        = list(string)
  default     = []
}

variable "nprd_apps_cluster_aliases" {
  description = "Additional hostname aliases for nprd-apps cluster TLS SANs"
  type        = list(string)
  default     = []
}

variable "prd_apps_cluster_hostname" {
  description = "Hostname for prd-apps cluster TLS SANs (used in RKE2 certificate generation)"
  type        = string
  default     = "prd-apps.example.com"
}

variable "prd_apps_cluster_primary_ip" {
  description = "Primary IP for prd-apps cluster TLS SANs"
  type        = string
  default     = "192.168.1.120"
}

variable "prd_apps_cluster_aliases" {
  description = "Additional hostname aliases for prd-apps cluster TLS SANs"
  type        = list(string)
  default     = []
}

variable "poc_apps_cluster_hostname" {
  description = "Hostname for poc-apps cluster TLS SANs (used in RKE2 certificate generation)"
  type        = string
  default     = "poc-apps.example.com"
}

variable "poc_apps_cluster_primary_ip" {
  description = "Primary IP for poc-apps cluster TLS SANs"
  type        = string
  default     = "192.168.1.130"
}

variable "poc_apps_cluster_aliases" {
  description = "Additional hostname aliases for poc-apps cluster TLS SANs"
  type        = list(string)
  default     = []
}

variable "rancher_manager_ip" {
  description = "IP address of Rancher Manager ingress (for downstream cluster registration)"
  type        = string
  default     = ""
}

variable "downstream_cluster_name" {
  description = "Name of a specific downstream cluster to register with Rancher Manager. Defaults to first non-manager cluster from clusters map (typically nprd-apps). Note: All downstream clusters are registered automatically when register_downstream_cluster is true."
  type        = string
  default     = "" # Empty = auto-detect first non-manager cluster
}

variable "downstream_cluster_id" {
  description = "DEPRECATED: Rancher cluster ID is now automatically fetched from Rancher API. This variable is kept for backward compatibility but is no longer used."
  type        = string
  default     = "" # Now fetched dynamically from Rancher API
}

# ============================================================================
# DEMOCRATIC CSI CONFIGURATION (community driver: democratic-csi)
# ============================================================================

variable "install_democratic_csi" {
  description = "Install Democratic CSI with TrueNAS backend"
  type        = bool
  default     = true
}

variable "democratic_csi_host" {
  description = "TrueNAS hostname or IP for Democratic CSI"
  type        = string
  default     = ""
}

variable "democratic_csi_api_key" {
  description = "TrueNAS API key for Democratic CSI (obtain from TrueNAS: System → API Keys)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "democratic_csi_dataset" {
  description = "TrueNAS dataset path for NFS (e.g., /mnt/SAS/RKE2)"
  type        = string
  default     = ""
}

variable "democratic_csi_user" {
  description = "TrueNAS username for API access (reference only)"
  type        = string
  default     = ""
}

variable "democratic_csi_protocol" {
  description = "TrueNAS API protocol (https or http)"
  type        = string
  default     = "https"
}

variable "democratic_csi_port" {
  description = "TrueNAS API port"
  type        = number
  default     = 443
}

variable "democratic_csi_allow_insecure" {
  description = "Allow insecure TLS (self-signed certs)"
  type        = bool
  default     = false
}

variable "democratic_csi_storage_class_name" {
  description = "Storage class name for Democratic CSI"
  type        = string
  default     = "truenas-nfs"
}

variable "democratic_csi_storage_class_default" {
  description = "Make Democratic CSI storage class the default"
  type        = bool
  default     = true
}

# ============================================================================
# TRUENAS CSI CONFIGURATION (official driver: truenas/truenas-csi)
# ============================================================================

variable "install_truenas_csi" {
  description = "Install official TrueNAS CSI driver. Requires TrueNAS SCALE 25.10+."
  type        = bool
  default     = false
}

variable "truenas_csi_host" {
  description = "TrueNAS hostname or IP for TrueNAS CSI"
  type        = string
  default     = ""
}

variable "truenas_csi_api_key" {
  description = "TrueNAS API key for TrueNAS CSI (obtain from TrueNAS: System → API Keys)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "truenas_csi_pool" {
  description = "ZFS pool name for volume creation (e.g., SAS). Volumes are created at pool root."
  type        = string
  default     = ""
}

variable "truenas_csi_protocol" {
  description = "TrueNAS API protocol (https or http)"
  type        = string
  default     = "https"
}

variable "truenas_csi_port" {
  description = "TrueNAS API port"
  type        = number
  default     = 443
}

variable "truenas_csi_allow_insecure" {
  description = "Allow insecure TLS (self-signed certs)"
  type        = bool
  default     = false
}

variable "truenas_csi_storage_class_name" {
  description = "Storage class name for TrueNAS CSI"
  type        = string
  default     = "truenas-csi-nfs"
}

variable "truenas_csi_storage_class_default" {
  description = "Make TrueNAS CSI storage class the default"
  type        = bool
  default     = false
}

variable "truenas_csi_image" {
  description = "CSI driver image. Use a patched image for multi-node scheduling (see docs/TRUENAS_CSI_MULTI_NODE.md)"
  type        = string
  default     = "quay.io/truenas_solutions/truenas-csi:latest"
}

variable "truenas_csi_image_pull_secret" {
  description = "Name of image pull secret for private registry (e.g., Harbor). If set, secret is copied to truenas-csi namespace and used. Leave empty for public images."
  type        = string
  default     = ""
}

variable "truenas_csi_image_pull_secret_file" {
  description = "Path to local secret YAML (e.g. config/harbor-registry-secret.yaml). Must be gitignored."
  type        = string
  default     = ""
}

# ============================================================================
# RKE2 REGISTRY MIRRORS (optional node-level containerd config)
# ============================================================================

variable "rke2_registries_yaml_file" {
  description = "Optional path to RKE2 registries.yaml (mirrors only). Harbor uses Let's Encrypt so no custom CA is needed. Gitignored under config/. See terraform/templates/rke2-registries.yaml.example. Empty or missing file skips."
  type        = string
  default     = "config/rke2-registries.yaml"
}

# ============================================================================
# ENVOY GATEWAY CONFIGURATION
# ============================================================================

variable "install_envoy_gateway" {
  description = "Whether to install Envoy Gateway on downstream clusters"
  type        = bool
  default     = true
}

variable "gateway_api_version" {
  description = "Gateway API CRDs version (deprecated - Envoy Gateway install.yaml includes CRDs automatically). Kept for compatibility but not used."
  type        = string
  default     = "v1.1.0"
}

variable "envoy_gateway_version" {
  description = "Envoy Gateway Helm chart version"
  type        = string
  default     = "v1.6.1"
}

variable "opensearch_operator_version" {
  description = "OpenSearch Kubernetes Operator Helm chart version"
  type        = string
  default     = "2.8.0"
}

variable "mongodb_operator_version" {
  description = "MongoDB Community Operator Helm chart version"
  type        = string
  default     = "0.13.0"
}

variable "cloudnativepg_operator_version" {
  description = "CloudNativePG Operator version (installed via manifest)"
  type        = string
  default     = "1.28.0"
}

variable "github_arc_controller_version" {
  description = "GitHub Actions Runner Controller (ARC) Helm chart version"
  type        = string
  default     = "0.13.1"
}

# ============================================================================
# PALWORLD OPERATOR CONFIGURATION
# ============================================================================

variable "install_palworld_operator_nprd" {
  description = "Install Palworld operator on nprd-apps (kubectl manifests from Harbor image)"
  type        = bool
  default     = false
}

variable "install_palworld_operator_prd" {
  description = "Install Palworld operator on prd-apps (kubectl manifests from Harbor image)"
  type        = bool
  default     = true
}

variable "install_palworld_operator_poc" {
  description = "Install Palworld operator on poc-apps (kubectl manifests from Harbor image)"
  type        = bool
  default     = false
}

variable "palworld_operator_image" {
  description = "Palworld operator image (Harbor). Prefer digest pin; Harbor currently only publishes :latest besides ad-hoc tags."
  type        = string
  default     = "harbor.dataknife.net/library/palworld-operator@sha256:89efffac532f9e44dfcde415be8c2103d7baa05762b96c60d47926252072650b"
}

variable "palworld_operator_image_pull_secret" {
  description = "Name of image pull secret for private registry (e.g. Harbor). Applied into palworld-operator-system."
  type        = string
  default     = "harbor-registry-secret"
}

variable "palworld_operator_image_pull_secret_file" {
  description = "Path to local secret YAML (e.g. config/harbor-registry-secret.yaml). Must be gitignored. Namespace in the file is rewritten to palworld-operator-system."
  type        = string
  default     = "config/harbor-registry-secret.yaml"
}

# ============================================================================
# KUBE-VIP CONFIGURATION
# ============================================================================

variable "install_kube_vip" {
  description = "Whether to install Kube-VIP on downstream clusters"
  type        = bool
  default     = true
}

variable "kube_vip_version" {
  description = "Kube-VIP version (latest: v1.0.3, see https://github.com/kube-vip/kube-vip/releases)"
  type        = string
  default     = "v1.0.3"
}

variable "kube_vip_ip_pools" {
  description = "IP address pools for Kube-VIP LoadBalancer services per cluster"
  type = map(object({
    addresses = string # e.g., "192.168.14.150-192.168.14.251"
  }))
  default = {
    "nprd-apps" = {
      addresses = "192.168.14.150-192.168.14.183"
    }
    "prd-apps" = {
      addresses = "192.168.14.184-192.168.14.217"
    }
    "poc-apps" = {
      addresses = "192.168.14.218-192.168.14.251"
    }
  }
}