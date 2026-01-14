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
# TRUENAS / DEMOCRATIC CSI CONFIGURATION
# ============================================================================

variable "truenas_host" {
  description = "TrueNAS hostname or IP address"
  type        = string
  default     = ""
}

variable "truenas_api_key" {
  description = "TrueNAS API key for democratic-csi (obtain from TrueNAS: System → API Keys)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "truenas_dataset" {
  description = "TrueNAS dataset path for NFS storage (e.g., /mnt/SAS/RKE2)"
  type        = string
  default     = ""
}

variable "truenas_user" {
  description = "TrueNAS username for API access"
  type        = string
  default     = ""
}

variable "truenas_protocol" {
  description = "TrueNAS API protocol (https or http)"
  type        = string
  default     = "https"
}

variable "truenas_port" {
  description = "TrueNAS API port"
  type        = number
  default     = 443
}

variable "truenas_allow_insecure" {
  description = "Allow insecure TLS connections to TrueNAS (for self-signed certs)"
  type        = bool
  default     = false
}

variable "csi_storage_class_name" {
  description = "Name for the democratic-csi storage class"
  type        = string
  default     = "truenas-nfs"
}

variable "csi_storage_class_default" {
  description = "Make the CSI storage class the default storage class"
  type        = bool
  default     = true
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