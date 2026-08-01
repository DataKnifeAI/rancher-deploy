# ============================================================================
# DOWNLOAD UBUNTU CLOUD IMAGE ON ALL PROXMOX NODES
# Downloads image to each node so VMs can be created on any node
# ============================================================================

locals {
  # List of all Proxmox nodes in the cluster
  proxmox_nodes = ["pve1", "pve2"]
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each = toset(local.proxmox_nodes)

  content_type        = "import"
  datastore_id        = "images-import"
  node_name           = each.value
  url                 = var.ubuntu_cloud_image_url
  file_name           = "ubuntu-noble-cloudimg-amd64.qcow2"
  overwrite           = true
  overwrite_unmanaged = true
}

# ============================================================================
# LOCAL VALUES FOR CLUSTER CONFIGURATION
# ============================================================================

locals {
  # Dynamically determine downstream cluster name (first non-manager cluster)
  downstream_cluster_name = var.downstream_cluster_name != "" ? var.downstream_cluster_name : [
    for name in keys(var.clusters) : name if name != "manager"
  ][0]

  # TrueNAS CSI: ZFS pool name for volume creation (volumes created at pool root)
  truenas_csi_pool = var.truenas_csi_pool != "" ? var.truenas_csi_pool : "tank"

  # Image pull secrets YAML for CSI when using private registry
  truenas_csi_image_pull_secrets = var.truenas_csi_image_pull_secret != "" ? "      imagePullSecrets:\n        - name: ${var.truenas_csi_image_pull_secret}" : ""

  # Harbor CRI files (gitignored under config/). Empty b64 skips writing on nodes.
  rke2_registry_ca_path = var.rke2_registry_ca_file != "" ? (
    startswith(var.rke2_registry_ca_file, "/") ? var.rke2_registry_ca_file : abspath("${path.root}/../${var.rke2_registry_ca_file}")
  ) : ""
  rke2_registries_yaml_path = var.rke2_registries_yaml_file != "" ? (
    startswith(var.rke2_registries_yaml_file, "/") ? var.rke2_registries_yaml_file : abspath("${path.root}/../${var.rke2_registries_yaml_file}")
  ) : ""
  rke2_registry_ca_b64 = (
    local.rke2_registry_ca_path != "" && fileexists(local.rke2_registry_ca_path)
  ) ? filebase64(local.rke2_registry_ca_path) : ""
  rke2_registries_yaml_b64 = (
    local.rke2_registries_yaml_path != "" && fileexists(local.rke2_registries_yaml_path)
  ) ? filebase64(local.rke2_registries_yaml_path) : ""

  # Apps clusters use TrueNAS CSI — set topology label at RKE2 join time.
  # Manager nodes do not use this CSI path and stay unlabeled.
  apps_rke2_node_labels = local.truenas_csi_pool != "" ? [
    "topology.truenas.io/pool=${local.truenas_csi_pool}"
  ] : []
}

# ============================================================================
# RANCHER MANAGER CLUSTER - PRIMARY NODE (manager-1)
# Builds first, initializes RKE2, generates cluster token
# ============================================================================

module "rancher_manager_primary" {
  source = "./modules/proxmox_vm"

  vm_name               = "rancher-manager-1"
  vm_id                 = var.vm_id_start_manager
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["manager"].storage

  cpu_cores    = var.clusters["manager"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["manager"].memory_mb
  disk_size_gb = var.clusters["manager"].disk_size_gb

  hostname    = "rancher-manager-1"
  ip_address  = "${var.clusters["manager"].ip_subnet}.${var.clusters["manager"].ip_start_octet}/24"
  gateway     = var.clusters["manager"].gateway
  dns_servers = var.clusters["manager"].dns_servers
  domain      = var.clusters["manager"].domain
  vlan_id     = var.clusters["manager"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - primary server (standalone, generates token)
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = true # NEW: marks this as primary node
  rke2_server_token  = ""   # Primary generates its own token
  rke2_server_ip     = ""   # No upstream server for primary
  cluster_hostname   = var.manager_cluster_hostname
  cluster_primary_ip = var.manager_cluster_primary_ip
  cluster_aliases    = var.manager_cluster_aliases

  # Harbor CRI (manager has no TrueNAS CSI topology label)
  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = []

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_cloud_image
  ]
}

# ============================================================================
# MANAGER CLUSTER - FETCH TOKEN FROM PRIMARY
# Fetches RKE2 token from primary node and stores locally
# ============================================================================

locals {
  manager_primary_ip = split("/", module.rancher_manager_primary.ip_address)[0]
  manager_token_file = "${abspath("${path.root}/../config")}/.manager-token"
}

resource "null_resource" "fetch_manager_token" {
  provisioner "local-exec" {
    command = "bash ${path.module}/fetch-token.sh ${var.ssh_private_key} ${local.manager_primary_ip} ${local.manager_token_file}"
  }

  # Clean up token file on destroy
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "rm -f ${pathexpand("${path.root}/../config")}/.manager-token"
  }

  depends_on = [
    module.rancher_manager_primary
  ]
}

# Read the token back from file (optional - may not exist during destroy)
# Using simple local read instead of trying to check with fileexists()
data "local_file" "manager_token" {
  count    = 1
  filename = local.manager_token_file
  depends_on = [
    null_resource.fetch_manager_token
  ]
}

# ============================================================================
# RANCHER MANAGER CLUSTER - SECONDARY NODES (manager-2, manager-3)
# Only builds after primary is ready and token is fetched
# ============================================================================

module "rancher_manager_additional" {
  source = "./modules/proxmox_vm"

  for_each = {
    for i in range(1, var.clusters["manager"].node_count) :
    "manager-${i + 1}" => {
      vm_id      = var.vm_id_start_manager + i
      hostname   = "rancher-manager-${i + 1}"
      ip_address = "${var.clusters["manager"].ip_subnet}.${var.clusters["manager"].ip_start_octet + i}/24"
      node_index = i
    }
  }

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["manager"].storage

  cpu_cores    = var.clusters["manager"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["manager"].memory_mb
  disk_size_gb = var.clusters["manager"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["manager"].gateway
  dns_servers = var.clusters["manager"].dns_servers
  domain      = var.clusters["manager"].domain
  vlan_id     = var.clusters["manager"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - secondary servers (join primary's cluster)
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = false                                                        # NEW: marks this as secondary node
  rke2_server_token  = try(trimspace(data.local_file.manager_token[0].content), "") # Token fetched locally from primary
  rke2_server_ip     = local.manager_primary_ip                                     # Primary IP
  cluster_hostname   = var.manager_cluster_hostname
  cluster_primary_ip = var.manager_cluster_primary_ip
  cluster_aliases    = var.manager_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = []

  # CRITICAL: Only build after primary is ready AND token is fetched
  depends_on = [
    module.rancher_manager_primary,
    data.local_file.manager_token
  ]
}

# ============================================================================
# MANAGER CLUSTER - VERIFICATION & KUBECONFIG
# Waits for all manager nodes to be ready, retrieves kubeconfig
# ============================================================================

module "rke2_manager" {
  source = "./modules/rke2_manager_cluster"

  cluster_name     = "rancher-manager"
  cluster_hostname = var.manager_cluster_hostname # Use FQDN instead of IP
  server_ips = concat(
    [split("/", module.rancher_manager_primary.ip_address)[0]],
    [for node in module.rancher_manager_additional : split("/", node.ip_address)[0]]
  )
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  dns_servers          = join(" ", var.clusters["manager"].dns_servers)

  depends_on = [
    module.rancher_manager_primary,
    module.rancher_manager_additional
  ]
}

# ============================================================================
# NPRD APPS CLUSTER - FETCH TOKEN FROM PRIMARY
# Fetches RKE2 token from apps primary node and stores locally
# ============================================================================

locals {
  nprd_apps_primary_ip = split("/", module.nprd_apps_primary.ip_address)[0]
  nprd_apps_token_file = "${abspath("${path.root}/../config")}/.nprd-apps-token"
}

resource "null_resource" "fetch_nprd_apps_token" {
  provisioner "local-exec" {
    command = "bash ${path.module}/fetch-token.sh ${var.ssh_private_key} ${local.nprd_apps_primary_ip} ${local.nprd_apps_token_file}"
  }

  depends_on = [
    module.nprd_apps_primary
  ]
}

# Read the nprd-apps token back from file (optional - may not exist during destroy)
data "local_file" "nprd_apps_token" {
  count    = 1
  filename = local.nprd_apps_token_file
  depends_on = [
    null_resource.fetch_nprd_apps_token
  ]
}

# ============================================================================
# NPRD APPS CLUSTER - PRIMARY NODE (apps-1)
# Only builds after manager cluster is ready
# ============================================================================

module "nprd_apps_primary" {
  source = "./modules/proxmox_vm"

  vm_name               = "nprd-apps-1"
  vm_id                 = var.vm_id_start_nprd_apps
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["nprd-apps"].storage

  cpu_cores    = var.clusters["nprd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["nprd-apps"].memory_mb
  disk_size_gb = var.clusters["nprd-apps"].disk_size_gb

  hostname    = "nprd-apps-1"
  ip_address  = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet}/24"
  gateway     = var.clusters["nprd-apps"].gateway
  dns_servers = var.clusters["nprd-apps"].dns_servers
  domain      = var.clusters["nprd-apps"].domain
  vlan_id     = var.clusters["nprd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - apps primary server
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = true
  rke2_server_token  = ""
  cluster_hostname   = var.nprd_apps_cluster_hostname
  cluster_primary_ip = var.nprd_apps_cluster_primary_ip
  cluster_aliases    = var.nprd_apps_cluster_aliases
  rke2_server_ip     = ""

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  # CRITICAL: Only build after manager cluster AND Rancher are fully ready
  depends_on = [
    module.rke2_manager,
    module.rancher_deployment,
    proxmox_virtual_environment_download_file.ubuntu_cloud_image
  ]
}

# ============================================================================
# NPRD APPS CLUSTER - SECONDARY NODES (apps-2, apps-3)
# Only builds after apps primary is ready
# ============================================================================

module "nprd_apps_additional" {
  source = "./modules/proxmox_vm"

  for_each = {
    for i in range(1, var.clusters["nprd-apps"].node_count) :
    "nprd-apps-${i + 1}" => {
      vm_id      = var.vm_id_start_nprd_apps + i
      hostname   = "nprd-apps-${i + 1}"
      ip_address = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet + i}/24"
      node_index = i
    }
  }

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["nprd-apps"].storage

  cpu_cores    = var.clusters["nprd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["nprd-apps"].memory_mb
  disk_size_gb = var.clusters["nprd-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["nprd-apps"].gateway
  dns_servers = var.clusters["nprd-apps"].dns_servers
  domain      = var.clusters["nprd-apps"].domain
  vlan_id     = var.clusters["nprd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - apps secondary servers
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.nprd_apps_token[0].content), "") # Token fetched locally from nprd-apps primary
  rke2_server_ip     = local.nprd_apps_primary_ip
  cluster_hostname   = var.nprd_apps_cluster_hostname
  cluster_primary_ip = var.nprd_apps_cluster_primary_ip
  cluster_aliases    = var.nprd_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.nprd_apps_primary,
    data.local_file.nprd_apps_token
  ]
}

# ============================================================================
# NPRD APPS CLUSTER - WORKER NODES (RKE2 Agent Mode)
# Dedicated worker nodes for application workloads
# Only created if worker_count > 0
# ============================================================================

module "nprd_apps_workers" {
  source = "./modules/proxmox_vm"

  for_each = var.clusters["nprd-apps"].worker_count > 0 ? {
    for i in range(1, var.clusters["nprd-apps"].worker_count + 1) :
    "nprd-apps-worker-${i}" => {
      vm_id      = var.vm_id_start_nprd_apps + var.clusters["nprd-apps"].node_count + i - 1
      hostname   = "nprd-apps-worker-${i}"
      ip_address = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet + var.clusters["nprd-apps"].node_count + i - 1}/24"
      node_index = var.clusters["nprd-apps"].node_count + i - 1
      # All VMs deploy on pve1
      proxmox_node = var.proxmox_node
    }
  } : {}

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = each.value.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].file_name
  datastore_id          = var.clusters["nprd-apps"].storage

  # Use worker-specific resources if provided, otherwise use server defaults
  cpu_cores    = var.clusters["nprd-apps"].worker_cpu_cores > 0 ? var.clusters["nprd-apps"].worker_cpu_cores : var.clusters["nprd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["nprd-apps"].worker_memory_mb > 0 ? var.clusters["nprd-apps"].worker_memory_mb : var.clusters["nprd-apps"].memory_mb
  disk_size_gb = var.clusters["nprd-apps"].worker_disk_size_gb > 0 ? var.clusters["nprd-apps"].worker_disk_size_gb : var.clusters["nprd-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["nprd-apps"].gateway
  dns_servers = var.clusters["nprd-apps"].dns_servers
  domain      = var.clusters["nprd-apps"].domain
  vlan_id     = var.clusters["nprd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - worker nodes (agent mode, NOT server mode)
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = false # Worker nodes run in agent mode
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.nprd_apps_token[0].content), "") # Token from apps primary
  rke2_server_ip     = local.nprd_apps_primary_ip                                     # Connect to primary server
  cluster_hostname   = var.nprd_apps_cluster_hostname
  cluster_primary_ip = var.nprd_apps_cluster_primary_ip
  cluster_aliases    = var.nprd_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.nprd_apps_primary,
    module.nprd_apps_additional, # CRITICAL: Workers must wait for all control nodes to be ready
    data.local_file.nprd_apps_token
  ]
}

# ============================================================================
# RANCHER DEPLOYMENT - ON MANAGER CLUSTER ONLY
# Installs cert-manager and Rancher via Helm after manager cluster is ready
# Must complete before apps cluster deployment so it can register with Rancher
# ============================================================================

module "rancher_deployment" {
  source = "./modules/rancher_cluster"

  cluster_name         = "rancher-manager"
  node_count           = 3
  kubeconfig_path      = module.rke2_manager.kubeconfig_path
  install_rancher      = var.install_rancher
  rancher_version      = var.rancher_version
  rancher_hostname     = var.rancher_hostname
  rancher_password     = var.rancher_password
  cert_manager_version = var.cert_manager_version

  depends_on = [
    module.rke2_manager
  ]
}

# ============================================================================
# CLEANUP GENERATED TOKENS AND VALUES ON DESTROY
# ============================================================================

resource "null_resource" "cleanup_tokens_on_destroy" {
  count = var.install_rancher ? 1 : 0

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      CONFIG_DIR="${path.root}/../config"
      echo "Cleaning up generated Rancher tokens and configs..."
      
      # Remove Rancher API token
      if [ -f "$${CONFIG_DIR}/.rancher-api-token" ]; then
        rm -f "$${CONFIG_DIR}/.rancher-api-token"
        echo "  ✓ Removed: $${CONFIG_DIR}/.rancher-api-token"
      fi
      
      # Note: Kubeconfig cleanup is handled by merge_kubeconfigs destroy provisioner
      # Individual files and merged config entries are cleaned up there
      
      echo "✓ Cleanup complete"
    EOT
  }

  depends_on = [
    module.rancher_deployment
  ]
}

# ============================================================================
# DOWNSTREAM CLUSTER REGISTRATION - MANIFEST-BASED APPROACH
# Uses manifestUrl endpoint for reliable, self-contained registration
# ============================================================================

# The registration manifest includes all necessary RBAC, ServiceAccount,
# Deployment, and ConfigMaps for cattle-cluster-agent pods to connect
# to and register with Rancher Manager.
#
# This approach is more reliable than system-agent-install.sh because it:
# - Uses public Rancher API endpoints (manifestUrl)
# - Provides self-contained Kubernetes manifests
# - Requires only kubectl apply, not external script downloads
# - Automatically includes proper CA certificate configuration

# ============================================================================
# NPRD APPS CLUSTER - VERIFICATION
# Waits for all apps nodes to be ready
# Only starts after Rancher is deployed on manager cluster
# ============================================================================

module "rke2_nprd_apps" {
  source = "./modules/rke2_downstream_cluster"

  cluster_name     = "nprd-apps"
  cluster_hostname = var.nprd_apps_cluster_hostname # Use FQDN instead of IP
  agent_ips = concat(
    # Server nodes (control plane)
    [split("/", module.nprd_apps_primary.ip_address)[0]],
    [for node in module.nprd_apps_additional : split("/", node.ip_address)[0]],
    # Worker nodes (if any)
    var.clusters["nprd-apps"].worker_count > 0 ? [
      for node in module.nprd_apps_workers : split("/", node.ip_address)[0]
    ] : []
  )
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  dns_servers          = join(" ", var.clusters["nprd-apps"].dns_servers)

  depends_on = [
    module.nprd_apps_primary,
    module.nprd_apps_additional,
    module.nprd_apps_workers, # Always include (empty if worker_count = 0)
    module.rancher_deployment # Wait for Rancher to be deployed first
  ]
}

# ============================================================================
# PRD APPS CLUSTER - FETCH TOKEN FROM PRIMARY
# Fetches RKE2 token from prd-apps primary node and stores locally
# ============================================================================

locals {
  prd_apps_primary_ip = split("/", module.prd_apps_primary.ip_address)[0]
  prd_apps_token_file = "${abspath("${path.root}/../config")}/.prd-apps-token"
}

resource "null_resource" "fetch_prd_apps_token" {
  provisioner "local-exec" {
    command = "bash ${path.module}/fetch-token.sh ${var.ssh_private_key} ${local.prd_apps_primary_ip} ${local.prd_apps_token_file}"
  }

  depends_on = [
    module.prd_apps_primary
  ]
}

# Read the prd-apps token back from file (optional - may not exist during destroy)
data "local_file" "prd_apps_token" {
  count    = 1
  filename = local.prd_apps_token_file
  depends_on = [
    null_resource.fetch_prd_apps_token
  ]
}

# ============================================================================
# PRD APPS CLUSTER - PRIMARY NODE (prd-apps-1)
# Only builds after manager cluster is ready
# ============================================================================

module "prd_apps_primary" {
  source = "./modules/proxmox_vm"

  vm_name               = "prd-apps-1"
  vm_id                 = var.vm_id_start_prd_apps
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["prd-apps"].storage

  cpu_cores    = var.clusters["prd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["prd-apps"].memory_mb
  disk_size_gb = var.clusters["prd-apps"].disk_size_gb

  hostname    = "prd-apps-1"
  ip_address  = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet}/24"
  gateway     = var.clusters["prd-apps"].gateway
  dns_servers = var.clusters["prd-apps"].dns_servers
  domain      = var.clusters["prd-apps"].domain
  vlan_id     = var.clusters["prd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - prd-apps primary server
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = true
  rke2_server_token  = ""
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases
  rke2_server_ip     = ""

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  # CRITICAL: Only build after manager cluster AND Rancher are fully ready
  depends_on = [
    module.rke2_manager,
    module.rancher_deployment,
    proxmox_virtual_environment_download_file.ubuntu_cloud_image
  ]
}

# ============================================================================
# PRD APPS CLUSTER - SECONDARY NODES (prd-apps-2, prd-apps-3)
# Only builds after prd-apps primary is ready
# ============================================================================

module "prd_apps_additional" {
  source = "./modules/proxmox_vm"

  for_each = {
    for i in range(1, var.clusters["prd-apps"].node_count) :
    "prd-apps-${i + 1}" => {
      vm_id      = var.vm_id_start_prd_apps + i
      hostname   = "prd-apps-${i + 1}"
      ip_address = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet + i}/24"
      node_index = i
    }
  }

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["prd-apps"].storage

  cpu_cores    = var.clusters["prd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["prd-apps"].memory_mb
  disk_size_gb = var.clusters["prd-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["prd-apps"].gateway
  dns_servers = var.clusters["prd-apps"].dns_servers
  domain      = var.clusters["prd-apps"].domain
  vlan_id     = var.clusters["prd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - prd-apps secondary servers
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.prd_apps_token[0].content), "") # Token fetched locally from prd-apps primary
  rke2_server_ip     = local.prd_apps_primary_ip
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.prd_apps_primary,
    data.local_file.prd_apps_token
  ]
}

# ============================================================================
# PRD APPS CLUSTER - WORKER NODES (RKE2 Agent Mode)
# Dedicated worker nodes for application workloads
# Only created if worker_count > 0
# ============================================================================

module "prd_apps_workers" {
  source = "./modules/proxmox_vm"

  for_each = var.clusters["prd-apps"].worker_count > 0 ? {
    for i in range(1, var.clusters["prd-apps"].worker_count + 1) :
    "prd-apps-worker-${i}" => {
      vm_id      = var.vm_id_start_prd_apps + var.clusters["prd-apps"].node_count + i - 1
      hostname   = "prd-apps-worker-${i}"
      ip_address = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet + var.clusters["prd-apps"].node_count + i - 1}/24"
      node_index = var.clusters["prd-apps"].node_count + i - 1
      # All VMs deploy on pve1
      proxmox_node = var.proxmox_node
    }
  } : {}

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = each.value.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].file_name
  datastore_id          = var.clusters["prd-apps"].storage

  # Use worker-specific resources if provided, otherwise use server defaults
  cpu_cores    = var.clusters["prd-apps"].worker_cpu_cores > 0 ? var.clusters["prd-apps"].worker_cpu_cores : var.clusters["prd-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["prd-apps"].worker_memory_mb > 0 ? var.clusters["prd-apps"].worker_memory_mb : var.clusters["prd-apps"].memory_mb
  disk_size_gb = var.clusters["prd-apps"].worker_disk_size_gb > 0 ? var.clusters["prd-apps"].worker_disk_size_gb : var.clusters["prd-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["prd-apps"].gateway
  dns_servers = var.clusters["prd-apps"].dns_servers
  domain      = var.clusters["prd-apps"].domain
  vlan_id     = var.clusters["prd-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - worker nodes (agent mode, NOT server mode)
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = false # Worker nodes run in agent mode
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.prd_apps_token[0].content), "") # Token from prd-apps primary
  rke2_server_ip     = local.prd_apps_primary_ip                                     # Connect to primary server
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.prd_apps_primary,
    module.prd_apps_additional, # CRITICAL: Workers must wait for all control nodes to be ready
    data.local_file.prd_apps_token
  ]
}

# ============================================================================
# PRD APPS CLUSTER - VERIFICATION
# Waits for all prd-apps nodes to be ready
# Only starts after Rancher is deployed on manager cluster
# ============================================================================

module "rke2_prd_apps" {
  source = "./modules/rke2_downstream_cluster"

  cluster_name     = "prd-apps"
  cluster_hostname = var.prd_apps_cluster_hostname # Use FQDN instead of IP
  agent_ips = concat(
    # Server nodes (control plane)
    [split("/", module.prd_apps_primary.ip_address)[0]],
    [for node in module.prd_apps_additional : split("/", node.ip_address)[0]],
    # Worker nodes (if any)
    var.clusters["prd-apps"].worker_count > 0 ? [
      for node in module.prd_apps_workers : split("/", node.ip_address)[0]
    ] : []
  )
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  dns_servers          = join(" ", var.clusters["prd-apps"].dns_servers)

  depends_on = [
    module.prd_apps_primary,
    module.prd_apps_additional,
    module.prd_apps_workers,  # Always include (empty if worker_count = 0)
    module.rancher_deployment # Wait for Rancher to be deployed first
  ]
}

# ============================================================================
# POC APPS CLUSTER - FETCH TOKEN FROM PRIMARY
# Fetches RKE2 token from poc-apps primary node and stores locally
# ============================================================================

locals {
  poc_apps_primary_ip = split("/", module.poc_apps_primary.ip_address)[0]
  poc_apps_token_file = "${abspath("${path.root}/../config")}/.poc-apps-token"
}

resource "null_resource" "fetch_poc_apps_token" {
  provisioner "local-exec" {
    command = "bash ${path.module}/fetch-token.sh ${var.ssh_private_key} ${local.poc_apps_primary_ip} ${local.poc_apps_token_file}"
  }

  depends_on = [
    module.poc_apps_primary
  ]
}

# Read the poc-apps token back from file (optional - may not exist during destroy)
data "local_file" "poc_apps_token" {
  count    = 1
  filename = local.poc_apps_token_file
  depends_on = [
    null_resource.fetch_poc_apps_token
  ]
}

# ============================================================================
# POC APPS CLUSTER - PRIMARY NODE (poc-apps-1)
# Only builds after manager cluster is ready
# ============================================================================

module "poc_apps_primary" {
  source = "./modules/proxmox_vm"

  vm_name               = "poc-apps-1"
  vm_id                 = var.vm_id_start_poc_apps
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["poc-apps"].storage

  cpu_cores    = var.clusters["poc-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["poc-apps"].memory_mb
  disk_size_gb = var.clusters["poc-apps"].disk_size_gb

  hostname    = "poc-apps-1"
  ip_address  = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet}/24"
  gateway     = var.clusters["poc-apps"].gateway
  dns_servers = var.clusters["poc-apps"].dns_servers
  domain      = var.clusters["poc-apps"].domain
  vlan_id     = var.clusters["poc-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - poc-apps primary server
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = true
  rke2_server_token  = ""
  cluster_hostname   = var.poc_apps_cluster_hostname
  cluster_primary_ip = var.poc_apps_cluster_primary_ip
  cluster_aliases    = var.poc_apps_cluster_aliases
  rke2_server_ip     = ""

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  # CRITICAL: Only build after manager cluster AND Rancher are fully ready
  depends_on = [
    module.rke2_manager,
    module.rancher_deployment,
    proxmox_virtual_environment_download_file.ubuntu_cloud_image
  ]
}

# ============================================================================
# POC APPS CLUSTER - SECONDARY NODES (poc-apps-2, poc-apps-3)
# Only builds after poc-apps primary is ready
# ============================================================================

module "poc_apps_additional" {
  source = "./modules/proxmox_vm"

  for_each = {
    for i in range(1, var.clusters["poc-apps"].node_count) :
    "poc-apps-${i + 1}" => {
      vm_id      = var.vm_id_start_poc_apps + i
      hostname   = "poc-apps-${i + 1}"
      ip_address = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet + i}/24"
      node_index = i
    }
  }

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["poc-apps"].storage

  cpu_cores    = var.clusters["poc-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["poc-apps"].memory_mb
  disk_size_gb = var.clusters["poc-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["poc-apps"].gateway
  dns_servers = var.clusters["poc-apps"].dns_servers
  domain      = var.clusters["poc-apps"].domain
  vlan_id     = var.clusters["poc-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - poc-apps secondary servers
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = true
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.poc_apps_token[0].content), "") # Token fetched locally from poc-apps primary
  rke2_server_ip     = local.poc_apps_primary_ip
  cluster_hostname   = var.poc_apps_cluster_hostname
  cluster_primary_ip = var.poc_apps_cluster_primary_ip
  cluster_aliases    = var.poc_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.poc_apps_primary,
    data.local_file.poc_apps_token
  ]
}

# ============================================================================
# POC APPS CLUSTER - WORKER NODES (RKE2 Agent Mode)
# Dedicated worker nodes for application workloads
# Only created if worker_count > 0
# ============================================================================

module "poc_apps_workers" {
  source = "./modules/proxmox_vm"

  for_each = var.clusters["poc-apps"].worker_count > 0 ? {
    for i in range(1, var.clusters["poc-apps"].worker_count + 1) :
    "poc-apps-worker-${i}" => {
      vm_id      = var.vm_id_start_poc_apps + var.clusters["poc-apps"].node_count + i - 1
      hostname   = "poc-apps-worker-${i}"
      ip_address = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet + var.clusters["poc-apps"].node_count + i - 1}/24"
      node_index = var.clusters["poc-apps"].node_count + i - 1
      # All VMs deploy on pve1
      proxmox_node = var.proxmox_node
    }
  } : {}

  vm_name               = each.value.hostname
  vm_id                 = each.value.vm_id
  proxmox_node          = each.value.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.proxmox_node].file_name
  datastore_id          = var.clusters["poc-apps"].storage

  # Use worker-specific resources if provided, otherwise use server defaults
  cpu_cores    = var.clusters["poc-apps"].worker_cpu_cores > 0 ? var.clusters["poc-apps"].worker_cpu_cores : var.clusters["poc-apps"].cpu_cores
  cpu_type     = var.vm_cpu_type
  memory_mb    = var.clusters["poc-apps"].worker_memory_mb > 0 ? var.clusters["poc-apps"].worker_memory_mb : var.clusters["poc-apps"].memory_mb
  disk_size_gb = var.clusters["poc-apps"].worker_disk_size_gb > 0 ? var.clusters["poc-apps"].worker_disk_size_gb : var.clusters["poc-apps"].disk_size_gb

  hostname    = each.value.hostname
  ip_address  = each.value.ip_address
  gateway     = var.clusters["poc-apps"].gateway
  dns_servers = var.clusters["poc-apps"].dns_servers
  domain      = var.clusters["poc-apps"].domain
  vlan_id     = var.clusters["poc-apps"].vlan_id

  ssh_private_key = var.ssh_private_key

  # RKE2 configuration - worker nodes (agent mode, NOT server mode)
  rke2_enabled       = true
  rke2_version       = var.rke2_version
  is_rke2_server     = false # Worker nodes run in agent mode
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.poc_apps_token[0].content), "") # Token from poc-apps primary
  rke2_server_ip     = local.poc_apps_primary_ip                                     # Connect to primary server
  cluster_hostname   = var.poc_apps_cluster_hostname
  cluster_primary_ip = var.poc_apps_cluster_primary_ip
  cluster_aliases    = var.poc_apps_cluster_aliases

  rke2_registry_ca_b64     = local.rke2_registry_ca_b64
  rke2_registries_yaml_b64 = local.rke2_registries_yaml_b64
  rke2_node_labels         = local.apps_rke2_node_labels

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.poc_apps_primary,
    module.poc_apps_additional, # CRITICAL: Workers must wait for all control nodes to be ready
    data.local_file.poc_apps_token
  ]
}

# ============================================================================
# POC APPS CLUSTER - VERIFICATION
# Waits for all poc-apps nodes to be ready
# Only starts after Rancher is deployed on manager cluster
# ============================================================================

module "rke2_poc_apps" {
  source = "./modules/rke2_downstream_cluster"

  cluster_name     = "poc-apps"
  cluster_hostname = var.poc_apps_cluster_hostname # Use FQDN instead of IP
  agent_ips = concat(
    # Server nodes (control plane)
    [split("/", module.poc_apps_primary.ip_address)[0]],
    [for node in module.poc_apps_additional : split("/", node.ip_address)[0]],
    # Worker nodes (if any)
    var.clusters["poc-apps"].worker_count > 0 ? [
      for node in module.poc_apps_workers : split("/", node.ip_address)[0]
    ] : []
  )
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  dns_servers          = join(" ", var.clusters["poc-apps"].dns_servers)

  depends_on = [
    module.poc_apps_primary,
    module.poc_apps_additional,
    module.poc_apps_workers,  # Always include (empty if worker_count = 0)
    module.rancher_deployment # Wait for Rancher to be deployed first
  ]
}

# ============================================================================
# TRUENAS TOPOLOGY LABELS (apps clusters)
# Ensures existing nodes get topology.truenas.io/pool=<pool> after kubeconfig is ready.
# New nodes also receive the label via RKE2 node-label in proxmox_vm bootstrap.
# Manager cluster is intentionally skipped (no TrueNAS CSI workload path).
# ============================================================================

resource "null_resource" "label_nprd_apps_truenas_topology" {
  triggers = {
    pool           = local.truenas_csi_pool
    cluster_module = module.rke2_nprd_apps.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG="${pathexpand("~/.kube/nprd-apps.yaml")}"
      POOL="${local.truenas_csi_pool}"
      echo "Labeling nprd-apps nodes with topology.truenas.io/pool=$${POOL}..."
      for i in $$(seq 1 60); do
        if kubectl --kubeconfig "$${KUBECONFIG}" get nodes &>/dev/null; then
          break
        fi
        sleep 5
      done
      kubectl --kubeconfig "$${KUBECONFIG}" label nodes --all "topology.truenas.io/pool=$${POOL}" --overwrite
      echo "✓ nprd-apps TrueNAS topology labels applied"
    EOT
  }

  depends_on = [module.rke2_nprd_apps]
}

resource "null_resource" "label_prd_apps_truenas_topology" {
  triggers = {
    pool           = local.truenas_csi_pool
    cluster_module = module.rke2_prd_apps.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG="${pathexpand("~/.kube/prd-apps.yaml")}"
      POOL="${local.truenas_csi_pool}"
      echo "Labeling prd-apps nodes with topology.truenas.io/pool=$${POOL}..."
      for i in $$(seq 1 60); do
        if kubectl --kubeconfig "$${KUBECONFIG}" get nodes &>/dev/null; then
          break
        fi
        sleep 5
      done
      kubectl --kubeconfig "$${KUBECONFIG}" label nodes --all "topology.truenas.io/pool=$${POOL}" --overwrite
      echo "✓ prd-apps TrueNAS topology labels applied"
    EOT
  }

  depends_on = [module.rke2_prd_apps]
}

resource "null_resource" "label_poc_apps_truenas_topology" {
  triggers = {
    pool           = local.truenas_csi_pool
    cluster_module = module.rke2_poc_apps.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG="${pathexpand("~/.kube/poc-apps.yaml")}"
      POOL="${local.truenas_csi_pool}"
      echo "Labeling poc-apps nodes with topology.truenas.io/pool=$${POOL}..."
      for i in $$(seq 1 60); do
        if kubectl --kubeconfig "$${KUBECONFIG}" get nodes &>/dev/null; then
          break
        fi
        sleep 5
      done
      kubectl --kubeconfig "$${KUBECONFIG}" label nodes --all "topology.truenas.io/pool=$${POOL}" --overwrite
      echo "✓ poc-apps TrueNAS topology labels applied"
    EOT
  }

  depends_on = [module.rke2_poc_apps]
}

# ENVOY GATEWAY DEPLOYMENT - DOWNSTREAM CLUSTERS
# Installs Envoy Gateway and Gateway API CRDs on downstream clusters
# ============================================================================

# Envoy Gateway for NPRD Apps Cluster
module "envoy_gateway_nprd_apps" {
  source = "./modules/envoy_gateway"

  cluster_name          = "nprd-apps"
  kubeconfig_path       = "~/.kube/nprd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_envoy_gateway = var.install_envoy_gateway
  gateway_api_version   = var.gateway_api_version
  envoy_gateway_version = var.envoy_gateway_version
  namespace             = "envoy-gateway-system"

  depends_on = [
    module.rke2_nprd_apps # Wait for cluster to be fully ready
  ]
}

# cert-manager for NPRD Apps Cluster
module "cert_manager_nprd_apps" {
  source = "./modules/cert_manager"

  cluster_name         = "nprd-apps"
  kubeconfig_path      = "~/.kube/nprd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  cert_manager_version = var.cert_manager_version
  namespace            = "cert-manager"

  depends_on = [
    module.rke2_nprd_apps # Wait for cluster to be fully ready
  ]
}

# Kube-VIP for NPRD Apps Cluster
module "kube_vip_nprd_apps" {
  source = "./modules/kube-vip"

  cluster_name      = "nprd-apps"
  kubeconfig_path   = "~/.kube/nprd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_kube_vip  = var.install_kube_vip
  kube_vip_version  = var.kube_vip_version
  namespace         = "kube-vip"
  ip_pool_addresses = try(var.kube_vip_ip_pools["nprd-apps"].addresses, "")

  depends_on = [
    module.rke2_nprd_apps # Wait for cluster to be fully ready
  ]
}

# Envoy Gateway for PRD Apps Cluster
module "envoy_gateway_prd_apps" {
  source = "./modules/envoy_gateway"

  cluster_name          = "prd-apps"
  kubeconfig_path       = "~/.kube/prd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_envoy_gateway = var.install_envoy_gateway
  gateway_api_version   = var.gateway_api_version
  envoy_gateway_version = var.envoy_gateway_version
  namespace             = "envoy-gateway-system"

  depends_on = [
    module.rke2_prd_apps # Wait for cluster to be fully ready
  ]
}

# cert-manager for PRD Apps Cluster
module "cert_manager_prd_apps" {
  source = "./modules/cert_manager"

  cluster_name         = "prd-apps"
  kubeconfig_path      = "~/.kube/prd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  cert_manager_version = var.cert_manager_version
  namespace            = "cert-manager"

  depends_on = [
    module.rke2_prd_apps # Wait for cluster to be fully ready
  ]
}

# Kube-VIP for PRD Apps Cluster
module "kube_vip_prd_apps" {
  source = "./modules/kube-vip"

  cluster_name      = "prd-apps"
  kubeconfig_path   = "~/.kube/prd-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_kube_vip  = var.install_kube_vip
  kube_vip_version  = var.kube_vip_version
  namespace         = "kube-vip"
  ip_pool_addresses = try(var.kube_vip_ip_pools["prd-apps"].addresses, "")

  depends_on = [
    module.rke2_prd_apps # Wait for cluster to be fully ready
  ]
}

# Envoy Gateway for POC Apps Cluster
module "envoy_gateway_poc_apps" {
  source = "./modules/envoy_gateway"

  cluster_name          = "poc-apps"
  kubeconfig_path       = "~/.kube/poc-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_envoy_gateway = var.install_envoy_gateway
  gateway_api_version   = var.gateway_api_version
  envoy_gateway_version = var.envoy_gateway_version
  namespace             = "envoy-gateway-system"

  depends_on = [
    module.rke2_poc_apps # Wait for cluster to be fully ready
  ]
}

# cert-manager for POC Apps Cluster
module "cert_manager_poc_apps" {
  source = "./modules/cert_manager"

  cluster_name         = "poc-apps"
  kubeconfig_path      = "~/.kube/poc-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  cert_manager_version = var.cert_manager_version
  namespace            = "cert-manager"

  depends_on = [
    module.rke2_poc_apps # Wait for cluster to be fully ready
  ]
}

# Kube-VIP for POC Apps Cluster
module "kube_vip_poc_apps" {
  source = "./modules/kube-vip"

  cluster_name      = "poc-apps"
  kubeconfig_path   = "~/.kube/poc-apps.yaml" # Path where rke2_downstream_cluster module creates kubeconfig
  install_kube_vip  = var.install_kube_vip
  kube_vip_version  = var.kube_vip_version
  namespace         = "kube-vip"
  ip_pool_addresses = try(var.kube_vip_ip_pools["poc-apps"].addresses, "")

  depends_on = [
    module.rke2_poc_apps # Wait for cluster to be fully ready
  ]
}

# ============================================================================
# CREATE DOWNSTREAM CLUSTER OBJECTS IN RANCHER
# Creates the clusters in Rancher to generate the cluster IDs
# ============================================================================

resource "null_resource" "create_nprd_apps_cluster" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating nprd-apps cluster object in Rancher..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Check if cluster already exists
      EXISTING=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | grep -o '"name":"nprd-apps"' || echo "")
      
      if [ -n "$${EXISTING}" ]; then
        echo "  ✓ Cluster 'nprd-apps' already exists in Rancher"
      else
        echo "  Creating cluster 'nprd-apps'..."
        curl -sk \
          -X POST \
          -H "Authorization: Bearer $${API_TOKEN}" \
          -H "Content-Type: application/json" \
          -d '{"name":"nprd-apps","description":"Non-production applications cluster"}' \
          "https://${var.rancher_hostname}/v3/clusters" > /dev/null
        echo "  ✓ Cluster created successfully"
      fi
    EOT
  }

  depends_on = [
    module.rancher_deployment,
    null_resource.fetch_manager_token
  ]
}

resource "null_resource" "create_prd_apps_cluster" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating prd-apps cluster object in Rancher..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Check if cluster already exists
      EXISTING=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | grep -o '"name":"prd-apps"' || echo "")
      
      if [ -n "$${EXISTING}" ]; then
        echo "  ✓ Cluster 'prd-apps' already exists in Rancher"
      else
        echo "  Creating cluster 'prd-apps'..."
        curl -sk \
          -X POST \
          -H "Authorization: Bearer $${API_TOKEN}" \
          -H "Content-Type: application/json" \
          -d '{"name":"prd-apps","description":"Production applications cluster"}' \
          "https://${var.rancher_hostname}/v3/clusters" > /dev/null
        echo "  ✓ Cluster created successfully"
      fi
    EOT
  }

  depends_on = [
    module.rancher_deployment,
    null_resource.fetch_manager_token
  ]
}

resource "null_resource" "create_poc_apps_cluster" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating poc-apps cluster object in Rancher..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Check if cluster already exists
      EXISTING=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | grep -o '"name":"poc-apps"' || echo "")
      
      if [ -n "$${EXISTING}" ]; then
        echo "  ✓ Cluster 'poc-apps' already exists in Rancher"
      else
        echo "  Creating cluster 'poc-apps'..."
        curl -sk \
          -X POST \
          -H "Authorization: Bearer $${API_TOKEN}" \
          -H "Content-Type: application/json" \
          -d '{"name":"poc-apps","description":"Proof of Concept applications cluster"}' \
          "https://${var.rancher_hostname}/v3/clusters" > /dev/null
        echo "  ✓ Cluster created successfully"
      fi
    EOT
  }

  depends_on = [
    module.rancher_deployment,
    null_resource.fetch_manager_token
  ]
}

# ============================================================================
# FETCH DOWNSTREAM CLUSTER IDS FROM RANCHER API
# Extracts the cluster IDs after cluster objects are created
# ============================================================================

locals {
  nprd_apps_cluster_id_file = "${abspath("${path.root}/../config")}/.nprd-apps-cluster-id"
  prd_apps_cluster_id_file  = "${abspath("${path.root}/../config")}/.prd-apps-cluster-id"
  poc_apps_cluster_id_file  = "${abspath("${path.root}/../config")}/.poc-apps-cluster-id"
}

resource "null_resource" "fetch_nprd_apps_cluster_id" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Fetching nprd-apps cluster ID from Rancher API..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Query Rancher API for the nprd-apps cluster (using jq for reliable JSON parsing)
      CLUSTER_ID=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | jq -r '.data[] | select(.name=="nprd-apps") | .id' 2>/dev/null || echo "")
      
      if [ -z "$${CLUSTER_ID}" ]; then
        echo "ERROR: Could not fetch nprd-apps cluster ID from Rancher API"
        echo "Ensure cluster 'nprd-apps' exists in Rancher Manager and API token is valid"
        exit 1
      fi
      
      echo "  ✓ Found nprd-apps cluster ID: $${CLUSTER_ID}"
      echo "$${CLUSTER_ID}" > "${abspath("${path.root}/../config")}/.nprd-apps-cluster-id"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "rm -f \"${abspath("${path.root}/../config")}/.nprd-apps-cluster-id\""
  }

  depends_on = [
    null_resource.create_nprd_apps_cluster
  ]
}

resource "null_resource" "fetch_prd_apps_cluster_id" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Fetching prd-apps cluster ID from Rancher API..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Query Rancher API for the prd-apps cluster (using jq for reliable JSON parsing)
      CLUSTER_ID=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | jq -r '.data[] | select(.name=="prd-apps") | .id' 2>/dev/null || echo "")
      
      if [ -z "$${CLUSTER_ID}" ]; then
        echo "ERROR: Could not fetch prd-apps cluster ID from Rancher API"
        echo "Ensure cluster 'prd-apps' exists in Rancher Manager and API token is valid"
        exit 1
      fi
      
      echo "  ✓ Found prd-apps cluster ID: $${CLUSTER_ID}"
      echo "$${CLUSTER_ID}" > "${abspath("${path.root}/../config")}/.prd-apps-cluster-id"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "rm -f \"${abspath("${path.root}/../config")}/.prd-apps-cluster-id\""
  }

  depends_on = [
    null_resource.create_prd_apps_cluster
  ]
}

resource "null_resource" "fetch_poc_apps_cluster_id" {
  count = var.register_downstream_cluster ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Fetching poc-apps cluster ID from Rancher API..."
      
      # Read API token from file
      API_TOKEN=$(cat "${path.root}/../config/.rancher-api-token")
      
      if [ -z "$${API_TOKEN}" ]; then
        echo "ERROR: API token file not found at ${path.root}/../config/.rancher-api-token"
        exit 1
      fi
      
      # Query Rancher API for the poc-apps cluster (using jq for reliable JSON parsing)
      CLUSTER_ID=$(curl -sk \
        -H "Authorization: Bearer $${API_TOKEN}" \
        "https://${var.rancher_hostname}/v3/clusters" \
        | jq -r '.data[] | select(.name=="poc-apps") | .id' 2>/dev/null || echo "")
      
      if [ -z "$${CLUSTER_ID}" ]; then
        echo "ERROR: Could not fetch poc-apps cluster ID from Rancher API"
        echo "Ensure cluster 'poc-apps' exists in Rancher Manager and API token is valid"
        exit 1
      fi
      
      echo "  ✓ Found poc-apps cluster ID: $${CLUSTER_ID}"
      echo "$${CLUSTER_ID}" > "${abspath("${path.root}/../config")}/.poc-apps-cluster-id"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "rm -f \"${abspath("${path.root}/../config")}/.poc-apps-cluster-id\""
  }

  depends_on = [
    null_resource.create_poc_apps_cluster
  ]
}

# Read the cluster IDs from files
data "local_file" "nprd_apps_cluster_id" {
  count    = var.register_downstream_cluster ? 1 : 0
  filename = local.nprd_apps_cluster_id_file

  depends_on = [
    null_resource.fetch_nprd_apps_cluster_id
  ]
}

data "local_file" "prd_apps_cluster_id" {
  count    = var.register_downstream_cluster ? 1 : 0
  filename = local.prd_apps_cluster_id_file

  depends_on = [
    null_resource.fetch_prd_apps_cluster_id
  ]
}

data "local_file" "poc_apps_cluster_id" {
  count    = var.register_downstream_cluster ? 1 : 0
  filename = local.poc_apps_cluster_id_file

  depends_on = [
    null_resource.fetch_poc_apps_cluster_id
  ]
}

# ============================================================================
# DOWNSTREAM CLUSTER REGISTRATION WITH RANCHER
# Applies cluster registration manifest to all nodes
# ============================================================================

module "rancher_downstream_registration_nprd_apps" {
  count = var.register_downstream_cluster ? 1 : 0

  source = "./modules/rancher_downstream_registration"

  rancher_url          = "https://${var.rancher_hostname}"
  rancher_token_file   = "/home/lee/git/rancher-deploy/config/.rancher-api-token"
  cluster_id           = trimspace(data.local_file.nprd_apps_cluster_id[0].content)
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  kubeconfig_path      = "~/.kube/nprd-apps.yaml"

  # Map of node names to IPs for NPRD apps cluster
  # Includes both server nodes and worker nodes (if any)
  cluster_nodes = merge(
    {
      "nprd-apps-1" = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet}"
      "nprd-apps-2" = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet + 1}"
      "nprd-apps-3" = "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet + 2}"
    },
    var.clusters["nprd-apps"].worker_count > 0 ? {
      for i in range(1, var.clusters["nprd-apps"].worker_count + 1) :
      "nprd-apps-worker-${i}" => "${var.clusters["nprd-apps"].ip_subnet}.${var.clusters["nprd-apps"].ip_start_octet + var.clusters["nprd-apps"].node_count + i - 1}"
    } : {}
  )

  depends_on = [
    module.rke2_nprd_apps,
    module.rancher_deployment
  ]
}

module "rancher_downstream_registration_prd_apps" {
  count = var.register_downstream_cluster ? 1 : 0

  source = "./modules/rancher_downstream_registration"

  rancher_url          = "https://${var.rancher_hostname}"
  rancher_token_file   = "/home/lee/git/rancher-deploy/config/.rancher-api-token"
  cluster_id           = trimspace(data.local_file.prd_apps_cluster_id[0].content)
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  kubeconfig_path      = "~/.kube/prd-apps.yaml"

  # Map of node names to IPs for PRD apps cluster
  # Includes both server nodes and worker nodes (if any)
  cluster_nodes = merge(
    {
      "prd-apps-1" = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet}"
      "prd-apps-2" = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet + 1}"
      "prd-apps-3" = "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet + 2}"
    },
    var.clusters["prd-apps"].worker_count > 0 ? {
      for i in range(1, var.clusters["prd-apps"].worker_count + 1) :
      "prd-apps-worker-${i}" => "${var.clusters["prd-apps"].ip_subnet}.${var.clusters["prd-apps"].ip_start_octet + var.clusters["prd-apps"].node_count + i - 1}"
    } : {}
  )

  depends_on = [
    module.rke2_prd_apps,
    module.rancher_deployment
  ]
}

module "rancher_downstream_registration_poc_apps" {
  count = var.register_downstream_cluster ? 1 : 0

  source = "./modules/rancher_downstream_registration"

  rancher_url          = "https://${var.rancher_hostname}"
  rancher_token_file   = "/home/lee/git/rancher-deploy/config/.rancher-api-token"
  cluster_id           = trimspace(data.local_file.poc_apps_cluster_id[0].content)
  ssh_private_key_path = var.ssh_private_key
  ssh_user             = "ubuntu"
  kubeconfig_path      = "~/.kube/poc-apps.yaml"

  # Map of node names to IPs for POC apps cluster
  # Includes both server nodes and worker nodes (if any)
  cluster_nodes = merge(
    {
      "poc-apps-1" = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet}"
      "poc-apps-2" = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet + 1}"
      "poc-apps-3" = "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet + 2}"
    },
    var.clusters["poc-apps"].worker_count > 0 ? {
      for i in range(1, var.clusters["poc-apps"].worker_count + 1) :
      "poc-apps-worker-${i}" => "${var.clusters["poc-apps"].ip_subnet}.${var.clusters["poc-apps"].ip_start_octet + var.clusters["poc-apps"].node_count + i - 1}"
    } : {}
  )

  depends_on = [
    module.rke2_poc_apps,
    module.rancher_deployment
  ]
}

# ============================================================================
# LEGACY: INSTALL SYSTEM-AGENT ON DOWNSTREAM CLUSTER NODES (DEPRECATED)
# Deprecated in favor of manifest-based registration
# Kept for reference but not used in production deployments
# ============================================================================

# NOTE: The old system_agent_install module approach had limitations:
# - Relied on /v3/connect/agent endpoint which doesn't respond from external nodes
# - Required downloading and executing RKE2's system-agent-install.sh script
# - Timeouts and connection issues on networks with strict egress controls
# 
# The new manifestUrl approach (above) is recommended:
# - Simpler: Just applies a Kubernetes manifest via kubectl
# - More reliable: Uses public Rancher API endpoints
# - Self-contained: Manifest includes all RBAC, Deployment, ConfigMaps
# - No external downloads needed beyond curl and kubectl

# module "system_agent_install" {
#   count = false  # DISABLED - use rancher_downstream_registration instead
#   
#   source = "./modules/system_agent_install"
#   
#   rancher_url            = "https://${var.rancher_hostname}"
#   rancher_token_file     = "/home/lee/git/rancher-deploy/config/.rancher-api-token"
#   cluster_id             = "c-7c2vb"
#   install_script_path    = "${path.module}/../scripts/install-system-agent.sh"
#   ssh_private_key_path   = var.ssh_private_key
#   ssh_user               = "ubuntu"
#   
#   cluster_nodes = {
#     "nprd-apps-1" = "192.168.14.110"
#     "nprd-apps-2" = "192.168.14.111"
#     "nprd-apps-3" = "192.168.14.112"
#   }
#   
#   depends_on = [
#     null_resource.register_nprd_cluster,
#     module.rke2_apps
#   ]
# }

# ============================================================================
# MERGE ALL KUBECONFIGS TO DEFAULT LOCATION
# Merges manager and apps cluster kubeconfigs into ~/.kube/config
# ============================================================================

resource "null_resource" "merge_kubeconfigs" {
  provisioner "local-exec" {
    when    = create
    command = <<-EOT
      echo "=========================================="
      echo "Merging all kubeconfigs to ~/.kube/config"
      echo "=========================================="
      
      mkdir -p ~/.kube
      MANAGER_CONFIG="$HOME/.kube/rancher-manager.yaml"
      NPRD_APPS_CONFIG="$HOME/.kube/nprd-apps.yaml"
      PRD_APPS_CONFIG="$HOME/.kube/prd-apps.yaml"
      POC_APPS_CONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Merge manager and apps kubeconfigs into default config
      # Create unique users for each cluster to avoid credential conflicts
      CONFIGS_TO_MERGE=""
      [ -f "$${MANAGER_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${MANAGER_CONFIG}"
      [ -f "$${NPRD_APPS_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${NPRD_APPS_CONFIG}"
      [ -f "$${PRD_APPS_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${PRD_APPS_CONFIG}"
      [ -f "$${POC_APPS_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${POC_APPS_CONFIG}"
      
      if [ -n "$${CONFIGS_TO_MERGE}" ]; then
        echo "Merging kubeconfigs..."
        CONFIGS_TO_MERGE=$${CONFIGS_TO_MERGE#:}  # Remove leading colon
        
        # First merge configs (this will create a single "default" user)
        KUBECONFIG="$${CONFIGS_TO_MERGE}" kubectl config view --flatten > $HOME/.kube/config.tmp
        mv $HOME/.kube/config.tmp $HOME/.kube/config
        chmod 600 $HOME/.kube/config
        
        # Extract certificates to temporary files for setting unique users
        TEMP_DIR=$(mktemp -d)
        trap "rm -rf $${TEMP_DIR}" EXIT
        
        # Extract manager user certs (use --raw to get actual data, not masked)
        kubectl config view --kubeconfig="$${MANAGER_CONFIG}" --raw -o json 2>/dev/null | \
          jq -r '.users[0].user."client-certificate-data"' 2>/dev/null | \
          base64 -d > "$${TEMP_DIR}/manager-cert.pem" 2>/dev/null || true
        kubectl config view --kubeconfig="$${MANAGER_CONFIG}" --raw -o json 2>/dev/null | \
          jq -r '.users[0].user."client-key-data"' 2>/dev/null | \
          base64 -d > "$${TEMP_DIR}/manager-key.pem" 2>/dev/null || true
        
        # Extract nprd-apps user certs (use --raw to get actual data, not masked)
        if [ -f "$${NPRD_APPS_CONFIG}" ]; then
          kubectl config view --kubeconfig="$${NPRD_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-certificate-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/nprd-apps-cert.pem" 2>/dev/null || true
          kubectl config view --kubeconfig="$${NPRD_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-key-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/nprd-apps-key.pem" 2>/dev/null || true
        fi
        
        # Extract prd-apps user certs (use --raw to get actual data, not masked)
        if [ -f "$${PRD_APPS_CONFIG}" ]; then
          kubectl config view --kubeconfig="$${PRD_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-certificate-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/prd-apps-cert.pem" 2>/dev/null || true
          kubectl config view --kubeconfig="$${PRD_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-key-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/prd-apps-key.pem" 2>/dev/null || true
        fi
        
        # Extract poc-apps user certs (use --raw to get actual data, not masked)
        if [ -f "$${POC_APPS_CONFIG}" ]; then
          kubectl config view --kubeconfig="$${POC_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-certificate-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/poc-apps-cert.pem" 2>/dev/null || true
          kubectl config view --kubeconfig="$${POC_APPS_CONFIG}" --raw -o json 2>/dev/null | \
            jq -r '.users[0].user."client-key-data"' 2>/dev/null | \
            base64 -d > "$${TEMP_DIR}/poc-apps-key.pem" 2>/dev/null || true
        fi
        
        # Create unique users for each cluster
        if [ -s "$${TEMP_DIR}/manager-cert.pem" ] && [ -s "$${TEMP_DIR}/manager-key.pem" ]; then
          kubectl config set-credentials manager-user \
            --client-certificate="$${TEMP_DIR}/manager-cert.pem" \
            --client-key="$${TEMP_DIR}/manager-key.pem" \
            --embed-certs=true 2>/dev/null || true
          kubectl config set-context rancher-manager --cluster=rancher-manager --user=manager-user 2>/dev/null || true
        fi
        
        if [ -s "$${TEMP_DIR}/nprd-apps-cert.pem" ] && [ -s "$${TEMP_DIR}/nprd-apps-key.pem" ]; then
          kubectl config set-credentials nprd-apps-user \
            --client-certificate="$${TEMP_DIR}/nprd-apps-cert.pem" \
            --client-key="$${TEMP_DIR}/nprd-apps-key.pem" \
            --embed-certs=true 2>/dev/null || true
          kubectl config set-context nprd-apps --cluster=nprd-apps --user=nprd-apps-user 2>/dev/null || true
        fi
        
        if [ -s "$${TEMP_DIR}/prd-apps-cert.pem" ] && [ -s "$${TEMP_DIR}/prd-apps-key.pem" ]; then
          kubectl config set-credentials prd-apps-user \
            --client-certificate="$${TEMP_DIR}/prd-apps-cert.pem" \
            --client-key="$${TEMP_DIR}/prd-apps-key.pem" \
            --embed-certs=true 2>/dev/null || true
          kubectl config set-context prd-apps --cluster=prd-apps --user=prd-apps-user 2>/dev/null || true
        fi
        
        if [ -s "$${TEMP_DIR}/poc-apps-cert.pem" ] && [ -s "$${TEMP_DIR}/poc-apps-key.pem" ]; then
          kubectl config set-credentials poc-apps-user \
            --client-certificate="$${TEMP_DIR}/poc-apps-cert.pem" \
            --client-key="$${TEMP_DIR}/poc-apps-key.pem" \
            --embed-certs=true 2>/dev/null || true
          kubectl config set-context poc-apps --cluster=poc-apps --user=poc-apps-user 2>/dev/null || true
        fi
        
        # Cleanup temp directory
        rm -rf "$${TEMP_DIR}"
        
        echo "✓ Merged kubeconfigs to $HOME/.kube/config with unique users"
      else
        echo "⚠ No kubeconfig files found to merge"
        echo "  Manager config: $${MANAGER_CONFIG} ($([ -f "$${MANAGER_CONFIG}" ] && echo 'exists' || echo 'missing'))"
        echo "  NPRD Apps config: $${NPRD_APPS_CONFIG} ($([ -f "$${NPRD_APPS_CONFIG}" ] && echo 'exists' || echo 'missing'))"
        echo "  PRD Apps config: $${PRD_APPS_CONFIG} ($([ -f "$${PRD_APPS_CONFIG}" ] && echo 'exists' || echo 'missing'))"
        echo "  POC Apps config: $${POC_APPS_CONFIG} ($([ -f "$${POC_APPS_CONFIG}" ] && echo 'exists' || echo 'missing'))"
      fi
      
      # Verify and set context names correctly after merge
      # Kubeconfigs should already have correct context names from retrieval step,
      # but verify and fix if needed
      
      # Check if contexts exist with expected names
      MANAGER_EXISTS=$(kubectl config get-contexts rancher-manager 2>/dev/null | grep -q rancher-manager && echo "yes" || echo "no")
      NPRD_APPS_EXISTS=$(kubectl config get-contexts nprd-apps 2>/dev/null | grep -q nprd-apps && echo "yes" || echo "no")
      PRD_APPS_EXISTS=$(kubectl config get-contexts prd-apps 2>/dev/null | grep -q prd-apps && echo "yes" || echo "no")
      POC_APPS_EXISTS=$(kubectl config get-contexts poc-apps 2>/dev/null | grep -q poc-apps && echo "yes" || echo "no")
      
      # If manager context doesn't exist, find and rename it
      if [ "$${MANAGER_EXISTS}" = "no" ]; then
        MANAGER_CONTEXT=$(kubectl config view -o jsonpath='{.contexts[?(@.context.cluster=="rancher-manager")].name}' 2>/dev/null || kubectl config view -o jsonpath='{.contexts[0].name}' 2>/dev/null || echo "")
        if [ -n "$${MANAGER_CONTEXT}" ] && [ "$${MANAGER_CONTEXT}" != "rancher-manager" ]; then
          echo "Renaming manager context: $${MANAGER_CONTEXT} -> rancher-manager"
          kubectl config rename-context "$${MANAGER_CONTEXT}" "rancher-manager" 2>/dev/null || true
        fi
      fi
      
      # If nprd-apps context doesn't exist, find and rename it
      if [ "$${NPRD_APPS_EXISTS}" = "no" ] && [ -f "$HOME/.kube/nprd-apps.yaml" ]; then
        NPRD_APPS_CONTEXT=$(kubectl config view -o jsonpath='{.contexts[?(@.context.cluster=="nprd-apps")].name}' 2>/dev/null || kubectl config view -o jsonpath='{.contexts[1].name}' 2>/dev/null || echo "")
        if [ -n "$${NPRD_APPS_CONTEXT}" ] && [ "$${NPRD_APPS_CONTEXT}" != "nprd-apps" ] && [ "$${NPRD_APPS_CONTEXT}" != "rancher-manager" ]; then
          echo "Renaming nprd-apps context: $${NPRD_APPS_CONTEXT} -> nprd-apps"
          kubectl config rename-context "$${NPRD_APPS_CONTEXT}" "nprd-apps" 2>/dev/null || true
        fi
      fi
      
      # If prd-apps context doesn't exist, find and rename it
      if [ "$${PRD_APPS_EXISTS}" = "no" ] && [ -f "$HOME/.kube/prd-apps.yaml" ]; then
        PRD_APPS_CONTEXT=$(kubectl config view -o jsonpath='{.contexts[?(@.context.cluster=="prd-apps")].name}' 2>/dev/null || kubectl config view -o jsonpath='{.contexts[2].name}' 2>/dev/null || echo "")
        if [ -n "$${PRD_APPS_CONTEXT}" ] && [ "$${PRD_APPS_CONTEXT}" != "prd-apps" ] && [ "$${PRD_APPS_CONTEXT}" != "rancher-manager" ] && [ "$${PRD_APPS_CONTEXT}" != "nprd-apps" ]; then
          echo "Renaming prd-apps context: $${PRD_APPS_CONTEXT} -> prd-apps"
          kubectl config rename-context "$${PRD_APPS_CONTEXT}" "prd-apps" 2>/dev/null || true
        fi
      fi
      
      # If poc-apps context doesn't exist, find and rename it
      if [ "$${POC_APPS_EXISTS}" = "no" ] && [ -f "$HOME/.kube/poc-apps.yaml" ]; then
        POC_APPS_CONTEXT=$(kubectl config view -o jsonpath='{.contexts[?(@.context.cluster=="poc-apps")].name}' 2>/dev/null || kubectl config view -o jsonpath='{.contexts[3].name}' 2>/dev/null || echo "")
        if [ -n "$${POC_APPS_CONTEXT}" ] && [ "$${POC_APPS_CONTEXT}" != "poc-apps" ] && [ "$${POC_APPS_CONTEXT}" != "rancher-manager" ] && [ "$${POC_APPS_CONTEXT}" != "nprd-apps" ] && [ "$${POC_APPS_CONTEXT}" != "prd-apps" ]; then
          echo "Renaming poc-apps context: $${POC_APPS_CONTEXT} -> poc-apps"
          kubectl config rename-context "$${POC_APPS_CONTEXT}" "poc-apps" 2>/dev/null || true
        fi
      fi
      
      # Verify cluster names are set correctly
      if kubectl config get-clusters rancher-manager &>/dev/null 2>&1; then
        echo "✓ Manager cluster: rancher-manager"
      fi
      if kubectl config get-clusters nprd-apps &>/dev/null 2>&1; then
        echo "✓ NPRD Apps cluster: nprd-apps"
      fi
      if kubectl config get-clusters prd-apps &>/dev/null 2>&1; then
        echo "✓ PRD Apps cluster: prd-apps"
      fi
      if kubectl config get-clusters poc-apps &>/dev/null 2>&1; then
        echo "✓ POC Apps cluster: poc-apps"
      fi
      
      # Set current context to manager if available
      if kubectl config get-contexts rancher-manager &>/dev/null 2>&1; then
        kubectl config use-context rancher-manager 2>/dev/null || true
        echo "✓ Current context set to: rancher-manager"
      fi
      
      echo ""
      echo "Available contexts:"
      kubectl config get-contexts --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (no contexts found)"
      echo ""
      echo "To switch clusters:"
      echo "  kubectl config use-context rancher-manager"
      echo "  kubectl config use-context nprd-apps"
      echo "  kubectl config use-context prd-apps"
      echo "  kubectl config use-context poc-apps"
      echo ""
      echo "Or use kubectx (if installed):"
      echo "  kubectx                    # List contexts"
      echo "  kubectx rancher-manager    # Switch to manager"
      echo "  kubectx nprd-apps          # Switch to nprd-apps"
      echo "  kubectx prd-apps           # Switch to prd-apps"
      echo "  kubectx poc-apps           # Switch to poc-apps"
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Cleaning up kubeconfig entries on destroy"
      echo "=========================================="
      
      MANAGER_CONFIG="$HOME/.kube/rancher-manager.yaml"
      NPRD_APPS_CONFIG="$HOME/.kube/nprd-apps.yaml"
      PRD_APPS_CONFIG="$HOME/.kube/prd-apps.yaml"
      POC_APPS_CONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Remove contexts and users from merged config
      if [ -f "$HOME/.kube/config" ]; then
        echo "Removing contexts and users from merged kubeconfig..."
        
        # Remove rancher-manager context and user
        kubectl config delete-context rancher-manager 2>/dev/null || true
        kubectl config unset users.manager-user 2>/dev/null || true
        
        # Remove nprd-apps context and user
        kubectl config delete-context nprd-apps 2>/dev/null || true
        kubectl config unset users.nprd-apps-user 2>/dev/null || true
        
        # Remove prd-apps context and user
        kubectl config delete-context prd-apps 2>/dev/null || true
        kubectl config unset users.prd-apps-user 2>/dev/null || true
        
        # Remove poc-apps context and user
        kubectl config delete-context poc-apps 2>/dev/null || true
        kubectl config unset users.poc-apps-user 2>/dev/null || true
        
        # Remove clusters if they exist
        kubectl config delete-cluster rancher-manager 2>/dev/null || true
        kubectl config delete-cluster nprd-apps 2>/dev/null || true
        kubectl config delete-cluster prd-apps 2>/dev/null || true
        kubectl config delete-cluster poc-apps 2>/dev/null || true
        
        echo "✓ Removed contexts and users from ~/.kube/config"
      fi
      
      # Remove individual kubeconfig files
      if [ -f "$${MANAGER_CONFIG}" ]; then
        rm -f "$${MANAGER_CONFIG}"
        echo "✓ Removed: $${MANAGER_CONFIG}"
      fi
      
      if [ -f "$${NPRD_APPS_CONFIG}" ]; then
        rm -f "$${NPRD_APPS_CONFIG}"
        echo "✓ Removed: $${NPRD_APPS_CONFIG}"
      fi
      
      if [ -f "$${PRD_APPS_CONFIG}" ]; then
        rm -f "$${PRD_APPS_CONFIG}"
        echo "✓ Removed: $${PRD_APPS_CONFIG}"
      fi
      
      if [ -f "$${POC_APPS_CONFIG}" ]; then
        rm -f "$${POC_APPS_CONFIG}"
        echo "✓ Removed: $${POC_APPS_CONFIG}"
      fi
      
      echo "✓ Kubeconfig cleanup complete"
    EOT
  }

  depends_on = [
    module.rancher_downstream_registration_nprd_apps,
    module.rancher_downstream_registration_prd_apps,
    module.rancher_downstream_registration_poc_apps
  ]
}

# ============================================================================
# DEMOCRATIC CSI STORAGE CLASS DEPLOYMENT
# Installs democratic-csi with TrueNAS and creates storage class
# Runs at the end of the plan after all clusters are ready
# Deploys to nprd-apps, prd-apps, and poc-apps clusters
# ============================================================================

resource "null_resource" "deploy_democratic_csi_nprd_apps" {
  count = var.install_democratic_csi && var.democratic_csi_host != "" && var.democratic_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Democratic CSI with TrueNAS to NPRD Apps Cluster"
      echo "=========================================="
      
      # Generate Helm values from Terraform variables
      echo "Generating Helm values from terraform.tfvars..."
      cd "${path.root}/.."
      ./scripts/generate-helm-values-from-tfvars.sh
      
      # Set kubeconfig to nprd-apps cluster
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Add Helm repository
      echo "Adding Helm repository..."
      helm repo add democratic-csi https://democratic-csi.github.io/charts/ 2>/dev/null || echo "Repository already added"
      helm repo update
      
      # Create namespace
      echo "Creating namespace..."
      kubectl create namespace democratic-csi --dry-run=client -o yaml | kubectl apply -f -
      
      # Install democratic-csi
      echo "Installing democratic-csi..."
      helm upgrade --install democratic-csi democratic-csi/democratic-csi \
        --namespace democratic-csi \
        -f helm-values/democratic-csi-truenas.yaml \
        --wait \
        --timeout 10m
      
      echo "✓ Democratic CSI installed"
      
      # Wait for pods to be ready
      echo "Waiting for pods to be ready..."
      kubectl wait --for=condition=ready pod -l app=democratic-csi-controller -n democratic-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=democratic-csi-node -n democratic-csi --timeout=5m || true
      
      # Verify storage class
      echo ""
      echo "Verifying storage class..."
      if kubectl get storageclass ${var.democratic_csi_storage_class_name} &>/dev/null; then
        echo "✓ Storage class '${var.democratic_csi_storage_class_name}' created"
        
        # Check if it's default
        IS_DEFAULT=$(kubectl get storageclass ${var.democratic_csi_storage_class_name} -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
        if [ "$IS_DEFAULT" = "true" ]; then
          echo "✓ Storage class '${var.democratic_csi_storage_class_name}' is set as default"
        elif [ "${var.democratic_csi_storage_class_default}" = "true" ]; then
          echo "Setting storage class as default..."
          # Remove default from any existing default storage class
          EXISTING_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "${var.democratic_csi_storage_class_name}" ]; then
            echo "  Removing default from: $EXISTING_DEFAULT"
            kubectl patch storageclass "$EXISTING_DEFAULT" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}' || true
          fi
          # Set as default
          kubectl patch storageclass ${var.democratic_csi_storage_class_name} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}' || true
          echo "✓ Storage class set as default"
        fi
      else
        echo "⚠ Storage class '${var.democratic_csi_storage_class_name}' not found"
        echo "  This may be normal if Helm installation is still in progress"
      fi
      
      echo ""
      echo "Storage Classes:"
      kubectl get storageclass
      
      echo ""
      echo "Democratic CSI Pods:"
      kubectl get pods -n democratic-csi
      
      echo ""
      echo "=========================================="
      echo "✓ Democratic CSI deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing Democratic CSI"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      if kubectl get namespace democratic-csi &>/dev/null; then
        echo "Uninstalling democratic-csi..."
        helm uninstall democratic-csi --namespace democratic-csi 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace democratic-csi --timeout=2m 2>/dev/null || true
        
        echo "✓ Democratic CSI removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    democratic_csi_host            = var.democratic_csi_host
    democratic_csi_api_key         = sha256(var.democratic_csi_api_key)
    democratic_csi_dataset         = var.democratic_csi_dataset
    democratic_csi_storage_class   = var.democratic_csi_storage_class_name
    democratic_csi_storage_default = tostring(var.democratic_csi_storage_class_default)
    helm_values_file               = filemd5("${path.root}/../scripts/generate-helm-values-from-tfvars.sh")
  }
}

resource "null_resource" "deploy_democratic_csi_prd_apps" {
  count = var.install_democratic_csi && var.democratic_csi_host != "" && var.democratic_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Democratic CSI with TrueNAS to PRD Apps Cluster"
      echo "=========================================="
      
      # Generate Helm values from Terraform variables
      echo "Generating Helm values from terraform.tfvars..."
      cd "${path.root}/.."
      ./scripts/generate-helm-values-from-tfvars.sh
      
      # Set kubeconfig to prd-apps cluster
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Add Helm repository
      echo "Adding Helm repository..."
      helm repo add democratic-csi https://democratic-csi.github.io/charts/ 2>/dev/null || echo "Repository already added"
      helm repo update
      
      # Create namespace
      echo "Creating namespace..."
      kubectl create namespace democratic-csi --dry-run=client -o yaml | kubectl apply -f -
      
      # Install democratic-csi
      echo "Installing democratic-csi..."
      helm upgrade --install democratic-csi democratic-csi/democratic-csi \
        --namespace democratic-csi \
        -f helm-values/democratic-csi-truenas.yaml \
        --wait \
        --timeout 10m
      
      echo "✓ Democratic CSI installed"
      
      # Wait for pods to be ready
      echo "Waiting for pods to be ready..."
      kubectl wait --for=condition=ready pod -l app=democratic-csi-controller -n democratic-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=democratic-csi-node -n democratic-csi --timeout=5m || true
      
      # Verify storage class
      echo ""
      echo "Verifying storage class..."
      if kubectl get storageclass ${var.democratic_csi_storage_class_name} &>/dev/null; then
        echo "✓ Storage class '${var.democratic_csi_storage_class_name}' created"
        
        # Check if it's default
        IS_DEFAULT=$(kubectl get storageclass ${var.democratic_csi_storage_class_name} -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
        if [ "$IS_DEFAULT" = "true" ]; then
          echo "✓ Storage class '${var.democratic_csi_storage_class_name}' is set as default"
        elif [ "${var.democratic_csi_storage_class_default}" = "true" ]; then
          echo "Setting storage class as default..."
          # Remove default from any existing default storage class
          EXISTING_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "${var.democratic_csi_storage_class_name}" ]; then
            echo "  Removing default from: $EXISTING_DEFAULT"
            kubectl patch storageclass "$EXISTING_DEFAULT" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}' || true
          fi
          # Set as default
          kubectl patch storageclass ${var.democratic_csi_storage_class_name} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}' || true
          echo "✓ Storage class set as default"
        fi
      else
        echo "⚠ Storage class '${var.democratic_csi_storage_class_name}' not found"
        echo "  This may be normal if Helm installation is still in progress"
      fi
      
      echo ""
      echo "Storage Classes:"
      kubectl get storageclass
      
      echo ""
      echo "Democratic CSI Pods:"
      kubectl get pods -n democratic-csi
      
      echo ""
      echo "=========================================="
      echo "✓ Democratic CSI deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing Democratic CSI from PRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      if kubectl get namespace democratic-csi &>/dev/null; then
        echo "Uninstalling democratic-csi..."
        helm uninstall democratic-csi --namespace democratic-csi 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace democratic-csi --timeout=2m 2>/dev/null || true
        
        echo "✓ Democratic CSI removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    democratic_csi_host            = var.democratic_csi_host
    democratic_csi_api_key         = sha256(var.democratic_csi_api_key)
    democratic_csi_dataset         = var.democratic_csi_dataset
    democratic_csi_storage_class   = var.democratic_csi_storage_class_name
    democratic_csi_storage_default = tostring(var.democratic_csi_storage_class_default)
    helm_values_file               = filemd5("${path.root}/../scripts/generate-helm-values-from-tfvars.sh")
  }
}

resource "null_resource" "deploy_democratic_csi_poc_apps" {
  count = var.install_democratic_csi && var.democratic_csi_host != "" && var.democratic_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Democratic CSI with TrueNAS to POC Apps Cluster"
      echo "=========================================="
      
      # Generate Helm values from Terraform variables
      echo "Generating Helm values from terraform.tfvars..."
      cd "${path.root}/.."
      ./scripts/generate-helm-values-from-tfvars.sh
      
      # Set kubeconfig to poc-apps cluster
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Add Helm repository
      echo "Adding Helm repository..."
      helm repo add democratic-csi https://democratic-csi.github.io/charts/ 2>/dev/null || echo "Repository already added"
      helm repo update
      
      # Create namespace
      echo "Creating namespace..."
      kubectl create namespace democratic-csi --dry-run=client -o yaml | kubectl apply -f -
      
      # Install democratic-csi
      echo "Installing democratic-csi..."
      helm upgrade --install democratic-csi democratic-csi/democratic-csi \
        --namespace democratic-csi \
        -f helm-values/democratic-csi-truenas.yaml \
        --wait \
        --timeout 10m
      
      echo "✓ Democratic CSI installed"
      
      # Wait for pods to be ready
      echo "Waiting for pods to be ready..."
      kubectl wait --for=condition=ready pod -l app=democratic-csi-controller -n democratic-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=democratic-csi-node -n democratic-csi --timeout=5m || true
      
      # Verify storage class
      echo ""
      echo "Verifying storage class..."
      if kubectl get storageclass ${var.democratic_csi_storage_class_name} &>/dev/null; then
        echo "✓ Storage class '${var.democratic_csi_storage_class_name}' created"
        
        # Check if it's default
        IS_DEFAULT=$(kubectl get storageclass ${var.democratic_csi_storage_class_name} -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
        if [ "$IS_DEFAULT" = "true" ]; then
          echo "✓ Storage class '${var.democratic_csi_storage_class_name}' is set as default"
        elif [ "${var.democratic_csi_storage_class_default}" = "true" ]; then
          echo "Setting storage class as default..."
          # Remove default from any existing default storage class
          EXISTING_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "${var.democratic_csi_storage_class_name}" ]; then
            echo "  Removing default from: $EXISTING_DEFAULT"
            kubectl patch storageclass "$EXISTING_DEFAULT" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}' || true
          fi
          # Set as default
          kubectl patch storageclass ${var.democratic_csi_storage_class_name} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}' || true
          echo "✓ Storage class set as default"
        fi
      else
        echo "⚠ Storage class '${var.democratic_csi_storage_class_name}' not found"
        echo "  This may be normal if Helm installation is still in progress"
      fi
      
      echo ""
      echo "Storage Classes:"
      kubectl get storageclass
      
      echo ""
      echo "Democratic CSI Pods:"
      kubectl get pods -n democratic-csi
      
      echo ""
      echo "=========================================="
      echo "✓ Democratic CSI deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing Democratic CSI from POC Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      if kubectl get namespace democratic-csi &>/dev/null; then
        echo "Uninstalling democratic-csi..."
        helm uninstall democratic-csi --namespace democratic-csi 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace democratic-csi --timeout=2m 2>/dev/null || true
        
        echo "✓ Democratic CSI removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    democratic_csi_host            = var.democratic_csi_host
    democratic_csi_api_key         = sha256(var.democratic_csi_api_key)
    democratic_csi_dataset         = var.democratic_csi_dataset
    democratic_csi_storage_class   = var.democratic_csi_storage_class_name
    democratic_csi_storage_default = tostring(var.democratic_csi_storage_class_default)
    helm_values_file               = filemd5("${path.root}/../scripts/generate-helm-values-from-tfvars.sh")
  }
}

# ============================================================================
# TRUENAS CSI DRIVER DEPLOYMENT (Official driver from truenas/truenas-csi)
# Requires TrueNAS SCALE 25.10+. Deploys to nprd-apps, prd-apps, poc-apps
# ============================================================================

resource "null_resource" "deploy_truenas_csi_nprd_apps" {
  count = var.install_truenas_csi && var.truenas_csi_host != "" && var.truenas_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying TrueNAS CSI Driver to NPRD Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'TRUENAS_CSI_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/truenas-csi-driver.yaml.tpl", {
    truenas_url        = "wss://${var.truenas_csi_host}/api/current"
    truenas_insecure   = var.truenas_csi_allow_insecure ? "true" : "false"
    default_pool       = local.truenas_csi_pool
    nfs_server         = var.truenas_csi_host
    iscsi_portal       = "${var.truenas_csi_host}:3260"
    truenas_csi_image  = var.truenas_csi_image
    image_pull_secrets = local.truenas_csi_image_pull_secrets
})}
TRUENAS_CSI_MANIFEST_END

      kubectl create namespace truenas-csi --dry-run=client -o yaml | kubectl apply -f -
      kubectl create secret generic truenas-api-credentials -n truenas-csi \
        --from-literal=api-key="$TRUENAS_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
      if [ -n "${var.truenas_csi_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.truenas_csi_image_pull_secret} -n truenas-csi &>/dev/null; then
          if [ -n "${var.truenas_csi_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.truenas_csi_image_pull_secret_file}..."
            kubectl apply -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}"
          else
            echo "WARNING: Image pull secret ${var.truenas_csi_image_pull_secret} not found. Set truenas_csi_image_pull_secret_file and ensure the file exists, or create with: kubectl create secret docker-registry ${var.truenas_csi_image_pull_secret} -n truenas-csi --docker-server=REGISTRY --docker-username=USER --docker-password=PASSWORD"
          fi
        else
          echo "✓ Image pull secret ${var.truenas_csi_image_pull_secret} already exists in truenas-csi"
        fi
      fi
      kubectl apply -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for TrueNAS CSI pods..."
      kubectl wait --for=condition=ready pod -l app=truenas-csi-controller -n truenas-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=truenas-csi-node -n truenas-csi --timeout=5m || true

      echo ""
      echo "Creating StorageClass ${var.truenas_csi_storage_class_name}..."
      kubectl apply -f - <<STORAGECLASS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${var.truenas_csi_storage_class_name}
provisioner: csi.truenas.io
parameters:
  protocol: "nfs"
  pool: "${local.truenas_csi_pool}"
  compression: "LZ4"
  nfs.mapAllUser: ""
  nfs.mapAllGroup: ""
  nfs.datasetPermissionsMode: "0777"
  nfs.datasetPermissionsUser: "0"
  nfs.datasetPermissionsGroup: "0"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
STORAGECLASS

      if [ "${var.truenas_csi_storage_class_default}" = "true" ]; then
        EXISTING=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
        if [ -n "$EXISTING" ] && [ "$EXISTING" != "${var.truenas_csi_storage_class_name}" ]; then
          kubectl patch storageclass "$EXISTING" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
        fi
        kubectl patch storageclass ${var.truenas_csi_storage_class_name} -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
        echo "✓ Storage class set as default"
      fi

      echo ""
      kubectl get pods -n truenas-csi
      kubectl get storageclass
      echo "✓ TrueNAS CSI deployment complete"
    EOT
environment = {
  TRUENAS_API_KEY = var.truenas_csi_api_key
}
}

provisioner "local-exec" {
  when       = destroy
  on_failure = continue
  command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      kubectl delete storageclass ${self.triggers.truenas_csi_storage_class} --ignore-not-found 2>/dev/null || true
      kubectl delete namespace truenas-csi --timeout=2m 2>/dev/null || true
      echo "✓ TrueNAS CSI removed"
    EOT
}

depends_on = [
  null_resource.merge_kubeconfigs,
  module.rke2_nprd_apps
]

triggers = {
  truenas_csi_host                   = var.truenas_csi_host
  truenas_csi_api_key                = sha256(var.truenas_csi_api_key)
  truenas_csi_pool                   = var.truenas_csi_pool
  truenas_csi_image                  = var.truenas_csi_image
  truenas_csi_image_pull_secret      = var.truenas_csi_image_pull_secret
  truenas_csi_image_pull_secret_file = var.truenas_csi_image_pull_secret_file
  truenas_csi_storage_class          = var.truenas_csi_storage_class_name
  truenas_csi_storage_default        = tostring(var.truenas_csi_storage_class_default)
  template_file                      = filemd5("${path.module}/templates/truenas-csi-driver.yaml.tpl")
  storage_class_params               = "nfs-mapall-empty-0777" # Bump when changing NFS permission params
}
}

resource "null_resource" "deploy_truenas_csi_prd_apps" {
  count = var.install_truenas_csi && var.truenas_csi_host != "" && var.truenas_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying TrueNAS CSI Driver to PRD Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'TRUENAS_CSI_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/truenas-csi-driver.yaml.tpl", {
    truenas_url        = "wss://${var.truenas_csi_host}/api/current"
    truenas_insecure   = var.truenas_csi_allow_insecure ? "true" : "false"
    default_pool       = local.truenas_csi_pool
    nfs_server         = var.truenas_csi_host
    iscsi_portal       = "${var.truenas_csi_host}:3260"
    truenas_csi_image  = var.truenas_csi_image
    image_pull_secrets = local.truenas_csi_image_pull_secrets
})}
TRUENAS_CSI_MANIFEST_END

      kubectl create namespace truenas-csi --dry-run=client -o yaml | kubectl apply -f -
      kubectl create secret generic truenas-api-credentials -n truenas-csi \
        --from-literal=api-key="$TRUENAS_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
      if [ -n "${var.truenas_csi_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.truenas_csi_image_pull_secret} -n truenas-csi &>/dev/null; then
          if [ -n "${var.truenas_csi_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.truenas_csi_image_pull_secret_file}..."
            kubectl apply -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}"
          else
            echo "WARNING: Image pull secret ${var.truenas_csi_image_pull_secret} not found. Set truenas_csi_image_pull_secret_file and ensure the file exists, or create with: kubectl create secret docker-registry ${var.truenas_csi_image_pull_secret} -n truenas-csi --docker-server=REGISTRY --docker-username=USER --docker-password=PASSWORD"
          fi
        else
          echo "✓ Image pull secret ${var.truenas_csi_image_pull_secret} already exists in truenas-csi"
        fi
      fi
      kubectl apply -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for TrueNAS CSI pods..."
      kubectl wait --for=condition=ready pod -l app=truenas-csi-controller -n truenas-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=truenas-csi-node -n truenas-csi --timeout=5m || true

      echo ""
      echo "Creating StorageClass ${var.truenas_csi_storage_class_name}..."
      kubectl apply -f - <<STORAGECLASS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${var.truenas_csi_storage_class_name}
provisioner: csi.truenas.io
parameters:
  protocol: "nfs"
  pool: "${local.truenas_csi_pool}"
  compression: "LZ4"
  nfs.mapAllUser: ""
  nfs.mapAllGroup: ""
  nfs.datasetPermissionsMode: "0777"
  nfs.datasetPermissionsUser: "0"
  nfs.datasetPermissionsGroup: "0"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
STORAGECLASS

      if [ "${var.truenas_csi_storage_class_default}" = "true" ]; then
        EXISTING=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
        if [ -n "$EXISTING" ] && [ "$EXISTING" != "${var.truenas_csi_storage_class_name}" ]; then
          kubectl patch storageclass "$EXISTING" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
        fi
        kubectl patch storageclass ${var.truenas_csi_storage_class_name} -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
        echo "✓ Storage class set as default"
      fi

      echo ""
      kubectl get pods -n truenas-csi
      kubectl get storageclass
      echo "✓ TrueNAS CSI deployment complete"
    EOT
environment = {
  TRUENAS_API_KEY = var.truenas_csi_api_key
}
}

provisioner "local-exec" {
  when       = destroy
  on_failure = continue
  command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      kubectl delete storageclass ${self.triggers.truenas_csi_storage_class} --ignore-not-found 2>/dev/null || true
      kubectl delete namespace truenas-csi --timeout=2m 2>/dev/null || true
      echo "✓ TrueNAS CSI removed"
    EOT
}

depends_on = [
  null_resource.merge_kubeconfigs,
  module.rke2_prd_apps
]

triggers = {
  truenas_csi_host                   = var.truenas_csi_host
  truenas_csi_api_key                = sha256(var.truenas_csi_api_key)
  truenas_csi_pool                   = var.truenas_csi_pool
  truenas_csi_image                  = var.truenas_csi_image
  truenas_csi_image_pull_secret      = var.truenas_csi_image_pull_secret
  truenas_csi_image_pull_secret_file = var.truenas_csi_image_pull_secret_file
  truenas_csi_storage_class          = var.truenas_csi_storage_class_name
  truenas_csi_storage_default        = tostring(var.truenas_csi_storage_class_default)
  template_file                      = filemd5("${path.module}/templates/truenas-csi-driver.yaml.tpl")
  storage_class_params               = "nfs-mapall-empty-0777" # Bump when changing NFS permission params
}
}

resource "null_resource" "deploy_truenas_csi_poc_apps" {
  count = var.install_truenas_csi && var.truenas_csi_host != "" && var.truenas_csi_api_key != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "=========================================="
      echo "Deploying TrueNAS CSI Driver to POC Apps Cluster"
      echo "=========================================="

      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"

      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      echo "✓ Cluster access verified"

      MANIFEST=$(mktemp)
      cat << 'TRUENAS_CSI_MANIFEST_END' > "$MANIFEST"
${templatefile("${path.module}/templates/truenas-csi-driver.yaml.tpl", {
    truenas_url        = "wss://${var.truenas_csi_host}/api/current"
    truenas_insecure   = var.truenas_csi_allow_insecure ? "true" : "false"
    default_pool       = local.truenas_csi_pool
    nfs_server         = var.truenas_csi_host
    iscsi_portal       = "${var.truenas_csi_host}:3260"
    truenas_csi_image  = var.truenas_csi_image
    image_pull_secrets = local.truenas_csi_image_pull_secrets
})}
TRUENAS_CSI_MANIFEST_END

      kubectl create namespace truenas-csi --dry-run=client -o yaml | kubectl apply -f -
      kubectl create secret generic truenas-api-credentials -n truenas-csi \
        --from-literal=api-key="$TRUENAS_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
      if [ -n "${var.truenas_csi_image_pull_secret}" ]; then
        if ! kubectl get secret ${var.truenas_csi_image_pull_secret} -n truenas-csi &>/dev/null; then
          if [ -n "${var.truenas_csi_image_pull_secret_file}" ] && [ -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}" ]; then
            echo "Applying image pull secret from local file ${var.truenas_csi_image_pull_secret_file}..."
            kubectl apply -f "${path.module}/../${var.truenas_csi_image_pull_secret_file}"
          else
            echo "WARNING: Image pull secret ${var.truenas_csi_image_pull_secret} not found. Set truenas_csi_image_pull_secret_file and ensure the file exists, or create with: kubectl create secret docker-registry ${var.truenas_csi_image_pull_secret} -n truenas-csi --docker-server=REGISTRY --docker-username=USER --docker-password=PASSWORD"
          fi
        else
          echo "✓ Image pull secret ${var.truenas_csi_image_pull_secret} already exists in truenas-csi"
        fi
      fi
      kubectl apply -f "$MANIFEST"
      rm -f "$MANIFEST"

      echo "Waiting for TrueNAS CSI pods..."
      kubectl wait --for=condition=ready pod -l app=truenas-csi-controller -n truenas-csi --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=truenas-csi-node -n truenas-csi --timeout=5m || true

      echo ""
      echo "Creating StorageClass ${var.truenas_csi_storage_class_name}..."
      kubectl apply -f - <<STORAGECLASS
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${var.truenas_csi_storage_class_name}
provisioner: csi.truenas.io
parameters:
  protocol: "nfs"
  pool: "${local.truenas_csi_pool}"
  compression: "LZ4"
  nfs.mapAllUser: ""
  nfs.mapAllGroup: ""
  nfs.datasetPermissionsMode: "0777"
  nfs.datasetPermissionsUser: "0"
  nfs.datasetPermissionsGroup: "0"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
STORAGECLASS

      if [ "${var.truenas_csi_storage_class_default}" = "true" ]; then
        EXISTING=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
        if [ -n "$EXISTING" ] && [ "$EXISTING" != "${var.truenas_csi_storage_class_name}" ]; then
          kubectl patch storageclass "$EXISTING" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
        fi
        kubectl patch storageclass ${var.truenas_csi_storage_class_name} -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
        echo "✓ Storage class set as default"
      fi

      echo ""
      kubectl get pods -n truenas-csi
      kubectl get storageclass
      echo "✓ TrueNAS CSI deployment complete"
    EOT
environment = {
  TRUENAS_API_KEY = var.truenas_csi_api_key
}
}

provisioner "local-exec" {
  when       = destroy
  on_failure = continue
  command    = <<-EOT
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      kubectl delete storageclass ${self.triggers.truenas_csi_storage_class} --ignore-not-found 2>/dev/null || true
      kubectl delete namespace truenas-csi --timeout=2m 2>/dev/null || true
      echo "✓ TrueNAS CSI removed"
    EOT
}

depends_on = [
  null_resource.merge_kubeconfigs,
  module.rke2_poc_apps
]

triggers = {
  truenas_csi_host                   = var.truenas_csi_host
  truenas_csi_api_key                = sha256(var.truenas_csi_api_key)
  truenas_csi_pool                   = var.truenas_csi_pool
  truenas_csi_image                  = var.truenas_csi_image
  truenas_csi_image_pull_secret      = var.truenas_csi_image_pull_secret
  truenas_csi_image_pull_secret_file = var.truenas_csi_image_pull_secret_file
  truenas_csi_storage_class          = var.truenas_csi_storage_class_name
  truenas_csi_storage_default        = tostring(var.truenas_csi_storage_class_default)
  template_file                      = filemd5("${path.module}/templates/truenas-csi-driver.yaml.tpl")
  storage_class_params               = "nfs-mapall-empty-0777" # Bump when changing NFS permission params
}
}

# ============================================================================
# CLOUDNATIVEPG OPERATOR DEPLOYMENT
# Installs CloudNativePG operator for PostgreSQL management
# Deploys to nprd-apps, prd-apps, and poc-apps clusters
# ============================================================================

resource "null_resource" "deploy_cloudnativepg_nprd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying CloudNativePG Operator to NPRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to nprd-apps cluster
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Install CloudNativePG operator using official manifest
      echo "Installing CloudNativePG operator version ${var.cloudnativepg_operator_version}..."
      CNPG_VERSION="${var.cloudnativepg_operator_version}"
      CNPG_RELEASE_VERSION=$(echo "$${CNPG_VERSION}" | cut -d. -f1,2)
      CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-$${CNPG_RELEASE_VERSION}/releases/cnpg-$${CNPG_VERSION}.yaml"
      
      # Apply the manifest with server-side apply
      kubectl apply --server-side -f "$${CNPG_MANIFEST_URL}" || {
        echo "⚠ Server-side apply failed, trying regular apply..."
        kubectl apply -f "$${CNPG_MANIFEST_URL}"
      }
      
      echo "✓ CloudNativePG operator manifest applied"
      
      # Wait for operator to be ready
      echo "Waiting for operator to be ready..."
      kubectl wait --for=condition=available deployment/cnpg-controller-manager \
        -n cnpg-system \
        --timeout=5m || {
        echo "⚠ Deployment may still be starting, checking status..."
        kubectl get deployment -n cnpg-system
      }
      
      # Verify installation
      echo ""
      echo "Verifying CloudNativePG installation..."
      kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=5m || true
      
      echo ""
      echo "CloudNativePG Pods:"
      kubectl get pods -n cnpg-system
      
      echo ""
      echo "CloudNativePG CRDs:"
      kubectl get crd | grep cnpg || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ CloudNativePG deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing CloudNativePG from NPRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/nprd-apps.yaml"
      
      if kubectl get namespace cnpg-system &>/dev/null; then
        echo "Removing CloudNativePG operator..."
        CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml"
        kubectl delete -f "$${CNPG_MANIFEST_URL}" --ignore-not-found=true || true
        
        echo "Deleting namespace..."
        kubectl delete namespace cnpg-system --timeout=2m 2>/dev/null || true
        
        echo "✓ CloudNativePG removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    cnpg_version = var.cloudnativepg_operator_version
  }
}

resource "null_resource" "deploy_cloudnativepg_prd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying CloudNativePG Operator to PRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to prd-apps cluster
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Install CloudNativePG operator using official manifest
      echo "Installing CloudNativePG operator version ${var.cloudnativepg_operator_version}..."
      CNPG_VERSION="${var.cloudnativepg_operator_version}"
      CNPG_RELEASE_VERSION=$(echo "$${CNPG_VERSION}" | cut -d. -f1,2)
      CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-$${CNPG_RELEASE_VERSION}/releases/cnpg-$${CNPG_VERSION}.yaml"
      
      # Apply the manifest with server-side apply
      kubectl apply --server-side -f "$${CNPG_MANIFEST_URL}" || {
        echo "⚠ Server-side apply failed, trying regular apply..."
        kubectl apply -f "$${CNPG_MANIFEST_URL}"
      }
      
      echo "✓ CloudNativePG operator manifest applied"
      
      # Wait for operator to be ready
      echo "Waiting for operator to be ready..."
      kubectl wait --for=condition=available deployment/cnpg-controller-manager \
        -n cnpg-system \
        --timeout=5m || {
        echo "⚠ Deployment may still be starting, checking status..."
        kubectl get deployment -n cnpg-system
      }
      
      # Verify installation
      echo ""
      echo "Verifying CloudNativePG installation..."
      kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=5m || true
      
      echo ""
      echo "CloudNativePG Pods:"
      kubectl get pods -n cnpg-system
      
      echo ""
      echo "CloudNativePG CRDs:"
      kubectl get crd | grep cnpg || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ CloudNativePG deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing CloudNativePG from PRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/prd-apps.yaml"
      
      if kubectl get namespace cnpg-system &>/dev/null; then
        echo "Removing CloudNativePG operator..."
        CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml"
        kubectl delete -f "$${CNPG_MANIFEST_URL}" --ignore-not-found=true || true
        
        echo "Deleting namespace..."
        kubectl delete namespace cnpg-system --timeout=2m 2>/dev/null || true
        
        echo "✓ CloudNativePG removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    cnpg_version = var.cloudnativepg_operator_version
  }
}

resource "null_resource" "deploy_cloudnativepg_poc_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying CloudNativePG Operator to POC Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to poc-apps cluster
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Install CloudNativePG operator using official manifest
      echo "Installing CloudNativePG operator version ${var.cloudnativepg_operator_version}..."
      CNPG_VERSION="${var.cloudnativepg_operator_version}"
      CNPG_RELEASE_VERSION=$(echo "$${CNPG_VERSION}" | cut -d. -f1,2)
      CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-$${CNPG_RELEASE_VERSION}/releases/cnpg-$${CNPG_VERSION}.yaml"
      
      # Apply the manifest with server-side apply
      kubectl apply --server-side -f "$${CNPG_MANIFEST_URL}" || {
        echo "⚠ Server-side apply failed, trying regular apply..."
        kubectl apply -f "$${CNPG_MANIFEST_URL}"
      }
      
      echo "✓ CloudNativePG operator manifest applied"
      
      # Wait for operator to be ready
      echo "Waiting for operator to be ready..."
      kubectl wait --for=condition=available deployment/cnpg-controller-manager \
        -n cnpg-system \
        --timeout=5m || {
        echo "⚠ Deployment may still be starting, checking status..."
        kubectl get deployment -n cnpg-system
      }
      
      # Verify installation
      echo ""
      echo "Verifying CloudNativePG installation..."
      kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=5m || true
      
      echo ""
      echo "CloudNativePG Pods:"
      kubectl get pods -n cnpg-system
      
      echo ""
      echo "CloudNativePG CRDs:"
      kubectl get crd | grep cnpg || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ CloudNativePG deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing CloudNativePG from POC Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/poc-apps.yaml"
      
      if kubectl get namespace cnpg-system &>/dev/null; then
        echo "Removing CloudNativePG operator..."
        CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml"
        kubectl delete -f "$${CNPG_MANIFEST_URL}" --ignore-not-found=true || true
        
        echo "Deleting namespace..."
        kubectl delete namespace cnpg-system --timeout=2m 2>/dev/null || true
        
        echo "✓ CloudNativePG removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    cnpg_version = var.cloudnativepg_operator_version
  }
}

# ============================================================================
# MONGODB COMMUNITY OPERATOR DEPLOYMENT
# Installs MongoDB Community Operator CRDs and operator for MongoDB management
# Required for Graylog Helm chart deployments
# Deploys to nprd-apps, prd-apps, and poc-apps clusters
# ============================================================================

resource "null_resource" "deploy_mongodb_community_operator_nprd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying MongoDB Community Operator to NPRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to nprd-apps cluster
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # MongoDB Community Operator configuration
      MONGODB_NAMESPACE="mongodb"
      MONGODB_RELEASE_NAME="community-operator"
      MONGODB_CHART="mongodb/community-operator"
      MONGODB_HELM_REPO="https://mongodb.github.io/helm-charts"
      MONGODB_VERSION="${var.mongodb_operator_version}"
      
      # Add MongoDB Helm repository
      echo "Adding MongoDB Helm repository..."
      helm repo add mongodb "$${MONGODB_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Clean up any existing CRDs that were installed manually (if present)
      # This is needed if a previous installation attempt failed
      echo "Checking for existing CRDs from previous installation..."
      if kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com &>/dev/null; then
        # Check if it's managed by Helm
        if ! kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q "Helm"; then
          echo "  Removing manually installed CRD (will be installed by Helm)..."
          kubectl delete crd mongodbcommunity.mongodbcommunity.mongodb.com --ignore-not-found=true || true
          sleep 2
        fi
      fi
      
      # Install MongoDB Community Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      # Configure operator to watch all namespaces (required for MongoDBCommunity resources in other namespaces)
      echo "Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
      if helm list -n "$${MONGODB_NAMESPACE}" 2>/dev/null | grep -q "^$${MONGODB_RELEASE_NAME}\\s"; then
        echo "  MongoDB Community Operator already installed, upgrading to version $${MONGODB_VERSION}..."
        helm upgrade "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      else
        echo "  Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
        helm install "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --create-namespace \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ MongoDB Community Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${MONGODB_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying MongoDB Community Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${MONGODB_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${MONGODB_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "MongoDB Community Operator Pods:"
      kubectl get pods -n "$${MONGODB_NAMESPACE}"
      
      echo ""
      echo "MongoDB Community Operator CRDs:"
      kubectl get crd | grep mongodbcommunity || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ MongoDB Community Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing MongoDB Community Operator from NPRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/nprd-apps.yaml"
      
      if kubectl get namespace mongodb &>/dev/null; then
        echo "Removing MongoDB Community Operator..."
        helm uninstall community-operator -n mongodb 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace mongodb --timeout=2m 2>/dev/null || true
        
        echo "✓ MongoDB Community Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    mongodb_operator_version = var.mongodb_operator_version
  }
}

resource "null_resource" "deploy_mongodb_community_operator_prd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying MongoDB Community Operator to PRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to prd-apps cluster
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # MongoDB Community Operator configuration
      MONGODB_NAMESPACE="mongodb"
      MONGODB_RELEASE_NAME="community-operator"
      MONGODB_CHART="mongodb/community-operator"
      MONGODB_HELM_REPO="https://mongodb.github.io/helm-charts"
      MONGODB_VERSION="${var.mongodb_operator_version}"
      
      # Add MongoDB Helm repository
      echo "Adding MongoDB Helm repository..."
      helm repo add mongodb "$${MONGODB_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Clean up any existing CRDs that were installed manually (if present)
      # This is needed if a previous installation attempt failed
      echo "Checking for existing CRDs from previous installation..."
      if kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com &>/dev/null; then
        # Check if it's managed by Helm
        if ! kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q "Helm"; then
          echo "  Removing manually installed CRD (will be installed by Helm)..."
          kubectl delete crd mongodbcommunity.mongodbcommunity.mongodb.com --ignore-not-found=true || true
          sleep 2
        fi
      fi
      
      # Install MongoDB Community Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      # Configure operator to watch all namespaces (required for MongoDBCommunity resources in other namespaces)
      echo "Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
      if helm list -n "$${MONGODB_NAMESPACE}" 2>/dev/null | grep -q "^$${MONGODB_RELEASE_NAME}\\s"; then
        echo "  MongoDB Community Operator already installed, upgrading to version $${MONGODB_VERSION}..."
        helm upgrade "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      else
        echo "  Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
        helm install "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --create-namespace \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ MongoDB Community Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${MONGODB_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying MongoDB Community Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${MONGODB_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${MONGODB_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "MongoDB Community Operator Pods:"
      kubectl get pods -n "$${MONGODB_NAMESPACE}"
      
      echo ""
      echo "MongoDB Community Operator CRDs:"
      kubectl get crd | grep mongodbcommunity || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ MongoDB Community Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing MongoDB Community Operator from PRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/prd-apps.yaml"
      
      if kubectl get namespace mongodb &>/dev/null; then
        echo "Removing MongoDB Community Operator..."
        helm uninstall community-operator -n mongodb 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace mongodb --timeout=2m 2>/dev/null || true
        
        echo "✓ MongoDB Community Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    mongodb_operator_version = var.mongodb_operator_version
  }
}

resource "null_resource" "deploy_mongodb_community_operator_poc_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying MongoDB Community Operator to POC Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to poc-apps cluster
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # MongoDB Community Operator configuration
      MONGODB_NAMESPACE="mongodb"
      MONGODB_RELEASE_NAME="community-operator"
      MONGODB_CHART="mongodb/community-operator"
      MONGODB_HELM_REPO="https://mongodb.github.io/helm-charts"
      MONGODB_VERSION="${var.mongodb_operator_version}"
      
      # Add MongoDB Helm repository
      echo "Adding MongoDB Helm repository..."
      helm repo add mongodb "$${MONGODB_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Clean up any existing CRDs that were installed manually (if present)
      # This is needed if a previous installation attempt failed
      echo "Checking for existing CRDs from previous installation..."
      if kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com &>/dev/null; then
        # Check if it's managed by Helm
        if ! kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null | grep -q "Helm"; then
          echo "  Removing manually installed CRD (will be installed by Helm)..."
          kubectl delete crd mongodbcommunity.mongodbcommunity.mongodb.com --ignore-not-found=true || true
          sleep 2
        fi
      fi
      
      # Install MongoDB Community Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      # Configure operator to watch all namespaces (required for MongoDBCommunity resources in other namespaces)
      echo "Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
      if helm list -n "$${MONGODB_NAMESPACE}" 2>/dev/null | grep -q "^$${MONGODB_RELEASE_NAME}\\s"; then
        echo "  MongoDB Community Operator already installed, upgrading to version $${MONGODB_VERSION}..."
        helm upgrade "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      else
        echo "  Installing MongoDB Community Operator version $${MONGODB_VERSION}..."
        helm install "$${MONGODB_RELEASE_NAME}" "$${MONGODB_CHART}" \
          --namespace "$${MONGODB_NAMESPACE}" \
          --create-namespace \
          --version "$${MONGODB_VERSION}" \
          --set operator.watchNamespace='*' \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ MongoDB Community Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${MONGODB_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying MongoDB Community Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${MONGODB_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${MONGODB_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "MongoDB Community Operator Pods:"
      kubectl get pods -n "$${MONGODB_NAMESPACE}"
      
      echo ""
      echo "MongoDB Community Operator CRDs:"
      kubectl get crd | grep mongodbcommunity || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ MongoDB Community Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing MongoDB Community Operator from POC Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/poc-apps.yaml"
      
      if kubectl get namespace mongodb &>/dev/null; then
        echo "Removing MongoDB Community Operator..."
        helm uninstall community-operator -n mongodb 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace mongodb --timeout=2m 2>/dev/null || true
        
        echo "✓ MongoDB Community Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    mongodb_operator_version = var.mongodb_operator_version
  }
}

# ============================================================================
# OPENSEARCH OPERATOR DEPLOYMENT
# Installs OpenSearch Kubernetes Operator for OpenSearch cluster management
# Deploys to nprd-apps, prd-apps, and poc-apps clusters
# ============================================================================

resource "null_resource" "deploy_opensearch_operator_nprd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying OpenSearch Operator to NPRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to nprd-apps cluster
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # OpenSearch Operator configuration
      OPENSEARCH_NAMESPACE="opensearch-operator-system"
      OPENSEARCH_RELEASE_NAME="opensearch-operator"
      OPENSEARCH_CHART="opensearch-operator/opensearch-operator"
      OPENSEARCH_HELM_REPO="https://opensearch-project.github.io/opensearch-k8s-operator/"
      OPENSEARCH_VERSION="${var.opensearch_operator_version}"
      
      # Add OpenSearch Helm repository
      echo "Adding OpenSearch Helm repository..."
      helm repo add opensearch-operator "$${OPENSEARCH_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Install OpenSearch Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      echo "Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
      if helm list -n "$${OPENSEARCH_NAMESPACE}" 2>/dev/null | grep -q "^$${OPENSEARCH_RELEASE_NAME}\\s"; then
        echo "  OpenSearch Operator already installed, upgrading to version $${OPENSEARCH_VERSION}..."
        helm upgrade "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      else
        echo "  Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
        helm install "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --create-namespace \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ OpenSearch Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying OpenSearch Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${OPENSEARCH_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "OpenSearch Operator Pods:"
      kubectl get pods -n "$${OPENSEARCH_NAMESPACE}"
      
      echo ""
      echo "OpenSearch Operator CRDs:"
      kubectl get crd | grep opensearch || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ OpenSearch Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing OpenSearch Operator from NPRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/nprd-apps.yaml"
      
      if kubectl get namespace opensearch-operator-system &>/dev/null; then
        echo "Removing OpenSearch Operator..."
        helm uninstall opensearch-operator -n opensearch-operator-system 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace opensearch-operator-system --timeout=2m 2>/dev/null || true
        
        echo "✓ OpenSearch Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    opensearch_operator_version = var.opensearch_operator_version
  }
}

resource "null_resource" "deploy_opensearch_operator_prd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying OpenSearch Operator to PRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to prd-apps cluster
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # OpenSearch Operator configuration
      OPENSEARCH_NAMESPACE="opensearch-operator-system"
      OPENSEARCH_RELEASE_NAME="opensearch-operator"
      OPENSEARCH_CHART="opensearch-operator/opensearch-operator"
      OPENSEARCH_HELM_REPO="https://opensearch-project.github.io/opensearch-k8s-operator/"
      OPENSEARCH_VERSION="${var.opensearch_operator_version}"
      
      # Add OpenSearch Helm repository
      echo "Adding OpenSearch Helm repository..."
      helm repo add opensearch-operator "$${OPENSEARCH_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Install OpenSearch Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      echo "Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
      if helm list -n "$${OPENSEARCH_NAMESPACE}" 2>/dev/null | grep -q "^$${OPENSEARCH_RELEASE_NAME}\\s"; then
        echo "  OpenSearch Operator already installed, upgrading to version $${OPENSEARCH_VERSION}..."
        helm upgrade "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      else
        echo "  Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
        helm install "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --create-namespace \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ OpenSearch Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying OpenSearch Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${OPENSEARCH_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "OpenSearch Operator Pods:"
      kubectl get pods -n "$${OPENSEARCH_NAMESPACE}"
      
      echo ""
      echo "OpenSearch Operator CRDs:"
      kubectl get crd | grep opensearch || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ OpenSearch Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing OpenSearch Operator from PRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/prd-apps.yaml"
      
      if kubectl get namespace opensearch-operator-system &>/dev/null; then
        echo "Removing OpenSearch Operator..."
        helm uninstall opensearch-operator -n opensearch-operator-system 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace opensearch-operator-system --timeout=2m 2>/dev/null || true
        
        echo "✓ OpenSearch Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    opensearch_operator_version = var.opensearch_operator_version
  }
}

resource "null_resource" "deploy_opensearch_operator_poc_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying OpenSearch Operator to POC Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to poc-apps cluster
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # OpenSearch Operator configuration
      OPENSEARCH_NAMESPACE="opensearch-operator-system"
      OPENSEARCH_RELEASE_NAME="opensearch-operator"
      OPENSEARCH_CHART="opensearch-operator/opensearch-operator"
      OPENSEARCH_HELM_REPO="https://opensearch-project.github.io/opensearch-k8s-operator/"
      OPENSEARCH_VERSION="${var.opensearch_operator_version}"
      
      # Add OpenSearch Helm repository
      echo "Adding OpenSearch Helm repository..."
      helm repo add opensearch-operator "$${OPENSEARCH_HELM_REPO}" 2>/dev/null || echo "Repository already added"
      helm repo update
      echo "✓ Helm repository added and updated"
      
      # Install OpenSearch Operator via Helm
      # Note: CRDs are installed automatically by the Helm chart
      echo "Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
      if helm list -n "$${OPENSEARCH_NAMESPACE}" 2>/dev/null | grep -q "^$${OPENSEARCH_RELEASE_NAME}\\s"; then
        echo "  OpenSearch Operator already installed, upgrading to version $${OPENSEARCH_VERSION}..."
        helm upgrade "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      else
        echo "  Installing OpenSearch Operator version $${OPENSEARCH_VERSION}..."
        helm install "$${OPENSEARCH_RELEASE_NAME}" "$${OPENSEARCH_CHART}" \
          --namespace "$${OPENSEARCH_NAMESPACE}" \
          --create-namespace \
          --version "$${OPENSEARCH_VERSION}" \
          --wait \
          --timeout 10m
      fi
      
      echo "✓ OpenSearch Operator installed"
      
      # Wait for operator pods to be ready
      echo "Waiting for operator pods to be ready..."
      sleep 5
      kubectl wait --for=condition=ready pod --all -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m 2>/dev/null || {
        echo "⚠ Some pods may still be starting"
      }
      
      # Verify installation
      echo ""
      echo "Verifying OpenSearch Operator installation..."
      DEPLOYMENT_NAME=$(kubectl get deployment -n "$${OPENSEARCH_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "$${DEPLOYMENT_NAME}" ]; then
        kubectl rollout status "deployment/$${DEPLOYMENT_NAME}" -n "$${OPENSEARCH_NAMESPACE}" --timeout=5m || true
      fi
      
      echo ""
      echo "OpenSearch Operator Pods:"
      kubectl get pods -n "$${OPENSEARCH_NAMESPACE}"
      
      echo ""
      echo "OpenSearch Operator CRDs:"
      kubectl get crd | grep opensearch || echo "CRDs may still be installing..."
      
      echo ""
      echo "=========================================="
      echo "✓ OpenSearch Operator deployment complete"
      echo "=========================================="
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing OpenSearch Operator from POC Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$${HOME}/.kube/poc-apps.yaml"
      
      if kubectl get namespace opensearch-operator-system &>/dev/null; then
        echo "Removing OpenSearch Operator..."
        helm uninstall opensearch-operator -n opensearch-operator-system 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace opensearch-operator-system --timeout=2m 2>/dev/null || true
        
        echo "✓ OpenSearch Operator removed"
      else
        echo "✓ Namespace already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    opensearch_operator_version = var.opensearch_operator_version
  }
}

# ============================================================================
# GITHUB ACTIONS RUNNER CONTROLLER (ARC) DEPLOYMENT
# Installs ARC controller for GitHub Actions runner management
# Deploys to nprd-apps, prd-apps, and poc-apps clusters
# Required before Fleet processes AutoscalingRunnerSet resources (official GitHub version)
# ============================================================================

resource "null_resource" "deploy_arc_nprd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Official GitHub ARC Controller to NPRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to nprd-apps cluster
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access nprd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # Official GitHub ARC uses OCI registry (no Helm repo needed)
      echo "Using official GitHub OCI chart (no Helm repo needed)"
      
      # Install official ARC controller using OCI chart
      echo "Installing official GitHub ARC controller version ${var.github_arc_controller_version}..."
      NAMESPACE="actions-runner-system"
      RELEASE_NAME="gha-runner-scale-set-controller"
      CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
      ARC_VERSION="${var.github_arc_controller_version}"
      
      # Check if already installed
      if helm list -n "$${NAMESPACE}" 2>/dev/null | grep -q "^$${RELEASE_NAME}\\s"; then
        echo "  ARC controller already installed, upgrading to version $${ARC_VERSION}..."
        helm upgrade "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --version "$${ARC_VERSION}" \
          --wait=false
      else
        echo "  Installing official ARC controller version $${ARC_VERSION}..."
        helm install "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --create-namespace \
          --version "$${ARC_VERSION}" \
          --wait=false
      fi
      
      echo "✓ Official ARC controller installed (version $${ARC_VERSION})"
      
      # Wait a moment for CRDs to be created
      sleep 5
      
      # Verify CRDs are installed (these are what Fleet needs)
      echo ""
      echo "Verifying ARC CRDs installation (Official Version)..."
      if kubectl get crd autoscalingrunnersets.actions.github.com &>/dev/null; then
        echo "✓ Required CRDs installed:"
        kubectl get crd | grep -E "autoscalingrunnersets|ephemeralrunnersets|ephemeralrunners" || true
      else
        echo "⚠ CRDs may still be installing, but controller chart is installed"
      fi
      
      echo ""
      echo "ARC Controller Pods:"
      kubectl get pods -n "$${NAMESPACE}" -l app.kubernetes.io/name=gha-runner-scale-set-controller || echo "Pods may still be starting..."
      
      echo ""
      echo "=========================================="
      echo "Configuring RBAC for ARC Controller"
      echo "=========================================="
      
      # Ensure managed-cicd namespace exists
      RUNNER_NAMESPACE="managed-cicd"
      if ! kubectl get namespace "$${RUNNER_NAMESPACE}" &>/dev/null; then
        echo "Creating namespace: $${RUNNER_NAMESPACE}"
        kubectl create namespace "$${RUNNER_NAMESPACE}" || true
      fi
      
      # Wait for controller ServiceAccount to be created
      echo "Waiting for controller ServiceAccount..."
      CONTROLLER_SA="gha-runner-scale-set-controller-gha-rs-controller"
      for i in {1..30}; do
        if kubectl get serviceaccount "$${CONTROLLER_SA}" -n "$${NAMESPACE}" &>/dev/null; then
          echo "✓ Controller ServiceAccount found"
          break
        fi
        if [ $i -eq 30 ]; then
          echo "⚠ Warning: Controller ServiceAccount not found, but continuing..."
        fi
        sleep 2
      done
      
      # Create Role for managing secrets and RBAC in managed-cicd namespace
      # The controller needs to:
      # 1. Read/create secrets (for github-app-secret authentication and listener config)
      # 2. Create/manage Roles and RoleBindings (for AutoscalingListener pods)
      echo "Creating Role for secret and RBAC access in $${RUNNER_NAMESPACE} namespace..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
      
      # Create RoleBinding to grant controller ServiceAccount permission to read secrets
      echo "Creating RoleBinding for controller secret access..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: $${CONTROLLER_SA}
  namespace: $${NAMESPACE}
roleRef:
  kind: Role
  name: arc-controller-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF
      
      echo "✓ RBAC configured: Controller can now read secrets in $${RUNNER_NAMESPACE} namespace"
      
      echo ""
      echo "=========================================="
      echo "✓ Official ARC deployment complete"
      echo "=========================================="
      echo ""
      echo "Note: CRDs are installed immediately. Fleet can now validate"
      echo "AutoscalingRunnerSet resources (official GitHub version)."
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing GitHub ARC Controller from NPRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      if helm list -n actions-runner-system 2>/dev/null | grep -qE "(actions-runner-controller|gha-runner-scale-set-controller)"; then
        echo "Uninstalling ARC controller..."
        helm uninstall actions-runner-controller -n actions-runner-system 2>/dev/null || true
        helm uninstall gha-runner-scale-set-controller -n actions-runner-system 2>/dev/null || true
        
        echo "Cleaning up RBAC resources..."
        kubectl delete rolebinding arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        kubectl delete role arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace actions-runner-system --timeout=2m 2>/dev/null || true
        
        echo "✓ ARC controller removed"
      else
        echo "✓ ARC controller already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_nprd_apps
  ]

  triggers = {
    arc_chart_version = var.github_arc_controller_version
  }
}

resource "null_resource" "deploy_arc_prd_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Official GitHub ARC Controller to PRD Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to prd-apps cluster
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access prd-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # Official GitHub ARC uses OCI registry (no Helm repo needed)
      echo "Using official GitHub OCI chart (no Helm repo needed)"
      
      # Install official ARC controller using OCI chart
      echo "Installing official GitHub ARC controller version ${var.github_arc_controller_version}..."
      NAMESPACE="actions-runner-system"
      RELEASE_NAME="gha-runner-scale-set-controller"
      CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
      ARC_VERSION="${var.github_arc_controller_version}"
      
      # Check if already installed
      if helm list -n "$${NAMESPACE}" 2>/dev/null | grep -q "^$${RELEASE_NAME}\\s"; then
        echo "  ARC controller already installed, upgrading to version $${ARC_VERSION}..."
        helm upgrade "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --version "$${ARC_VERSION}" \
          --wait=false
      else
        echo "  Installing official ARC controller version $${ARC_VERSION}..."
        helm install "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --create-namespace \
          --version "$${ARC_VERSION}" \
          --wait=false
      fi
      
      echo "✓ Official ARC controller installed (version $${ARC_VERSION})"
      
      # Wait a moment for CRDs to be created
      sleep 5
      
      # Verify CRDs are installed (these are what Fleet needs)
      echo ""
      echo "Verifying ARC CRDs installation (Official Version)..."
      if kubectl get crd autoscalingrunnersets.actions.github.com &>/dev/null; then
        echo "✓ Required CRDs installed:"
        kubectl get crd | grep -E "autoscalingrunnersets|ephemeralrunnersets|ephemeralrunners" || true
      else
        echo "⚠ CRDs may still be installing, but controller chart is installed"
      fi
      
      echo ""
      echo "ARC Controller Pods:"
      kubectl get pods -n "$${NAMESPACE}" -l app.kubernetes.io/name=gha-runner-scale-set-controller || echo "Pods may still be starting..."
      
      echo ""
      echo "=========================================="
      echo "Configuring RBAC for ARC Controller"
      echo "=========================================="
      
      # Ensure managed-cicd namespace exists
      RUNNER_NAMESPACE="managed-cicd"
      if ! kubectl get namespace "$${RUNNER_NAMESPACE}" &>/dev/null; then
        echo "Creating namespace: $${RUNNER_NAMESPACE}"
        kubectl create namespace "$${RUNNER_NAMESPACE}" || true
      fi
      
      # Wait for controller ServiceAccount to be created
      echo "Waiting for controller ServiceAccount..."
      CONTROLLER_SA="gha-runner-scale-set-controller-gha-rs-controller"
      for i in {1..30}; do
        if kubectl get serviceaccount "$${CONTROLLER_SA}" -n "$${NAMESPACE}" &>/dev/null; then
          echo "✓ Controller ServiceAccount found"
          break
        fi
        if [ $i -eq 30 ]; then
          echo "⚠ Warning: Controller ServiceAccount not found, but continuing..."
        fi
        sleep 2
      done
      
      # Create Role for managing secrets and RBAC in managed-cicd namespace
      # The controller needs to:
      # 1. Read/create secrets (for github-app-secret authentication and listener config)
      # 2. Create/manage Roles and RoleBindings (for AutoscalingListener pods)
      echo "Creating Role for secret and RBAC access in $${RUNNER_NAMESPACE} namespace..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
      
      # Create RoleBinding to grant controller ServiceAccount permission to read secrets
      echo "Creating RoleBinding for controller secret access..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: $${CONTROLLER_SA}
  namespace: $${NAMESPACE}
roleRef:
  kind: Role
  name: arc-controller-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF
      
      echo "✓ RBAC configured: Controller can now read secrets in $${RUNNER_NAMESPACE} namespace"
      
      echo ""
      echo "=========================================="
      echo "✓ Official ARC deployment complete"
      echo "=========================================="
      echo ""
      echo "Note: CRDs are installed immediately. Fleet can now validate"
      echo "AutoscalingRunnerSet resources (official GitHub version)."
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing GitHub ARC Controller from PRD Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      if helm list -n actions-runner-system 2>/dev/null | grep -qE "(actions-runner-controller|gha-runner-scale-set-controller)"; then
        echo "Uninstalling ARC controller..."
        helm uninstall actions-runner-controller -n actions-runner-system 2>/dev/null || true
        helm uninstall gha-runner-scale-set-controller -n actions-runner-system 2>/dev/null || true
        
        echo "Cleaning up RBAC resources..."
        kubectl delete rolebinding arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        kubectl delete role arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace actions-runner-system --timeout=2m 2>/dev/null || true
        
        echo "✓ ARC controller removed"
      else
        echo "✓ ARC controller already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_prd_apps
  ]

  triggers = {
    arc_chart_version = var.github_arc_controller_version
  }
}

resource "null_resource" "deploy_arc_poc_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=========================================="
      echo "Deploying Official GitHub ARC Controller to POC Apps Cluster"
      echo "=========================================="
      
      # Set kubeconfig to poc-apps cluster
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      # Verify cluster access
      if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access poc-apps cluster"
        exit 1
      fi
      
      echo "✓ Cluster access verified"
      
      # Check if Helm is available
      if ! command -v helm &>/dev/null; then
        echo "ERROR: helm not found"
        exit 1
      fi
      
      # Official GitHub ARC uses OCI registry (no Helm repo needed)
      echo "Using official GitHub OCI chart (no Helm repo needed)"
      
      # Install official ARC controller using OCI chart
      echo "Installing official GitHub ARC controller version ${var.github_arc_controller_version}..."
      NAMESPACE="actions-runner-system"
      RELEASE_NAME="gha-runner-scale-set-controller"
      CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
      ARC_VERSION="${var.github_arc_controller_version}"
      
      # Check if already installed
      if helm list -n "$${NAMESPACE}" 2>/dev/null | grep -q "^$${RELEASE_NAME}\\s"; then
        echo "  ARC controller already installed, upgrading to version $${ARC_VERSION}..."
        helm upgrade "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --version "$${ARC_VERSION}" \
          --wait=false
      else
        echo "  Installing official ARC controller version $${ARC_VERSION}..."
        helm install "$${RELEASE_NAME}" "$${CHART}" \
          --namespace "$${NAMESPACE}" \
          --create-namespace \
          --version "$${ARC_VERSION}" \
          --wait=false
      fi
      
      echo "✓ Official ARC controller installed (version $${ARC_VERSION})"
      
      # Wait a moment for CRDs to be created
      sleep 5
      
      # Verify CRDs are installed (these are what Fleet needs)
      echo ""
      echo "Verifying ARC CRDs installation (Official Version)..."
      if kubectl get crd autoscalingrunnersets.actions.github.com &>/dev/null; then
        echo "✓ Required CRDs installed:"
        kubectl get crd | grep -E "autoscalingrunnersets|ephemeralrunnersets|ephemeralrunners" || true
      else
        echo "⚠ CRDs may still be installing, but controller chart is installed"
      fi
      
      echo ""
      echo "ARC Controller Pods:"
      kubectl get pods -n "$${NAMESPACE}" -l app.kubernetes.io/name=gha-runner-scale-set-controller || echo "Pods may still be starting..."
      
      echo ""
      echo "=========================================="
      echo "Configuring RBAC for ARC Controller"
      echo "=========================================="
      
      # Ensure managed-cicd namespace exists
      RUNNER_NAMESPACE="managed-cicd"
      if ! kubectl get namespace "$${RUNNER_NAMESPACE}" &>/dev/null; then
        echo "Creating namespace: $${RUNNER_NAMESPACE}"
        kubectl create namespace "$${RUNNER_NAMESPACE}" || true
      fi
      
      # Wait for controller ServiceAccount to be created
      echo "Waiting for controller ServiceAccount..."
      CONTROLLER_SA="gha-runner-scale-set-controller-gha-rs-controller"
      for i in {1..30}; do
        if kubectl get serviceaccount "$${CONTROLLER_SA}" -n "$${NAMESPACE}" &>/dev/null; then
          echo "✓ Controller ServiceAccount found"
          break
        fi
        if [ $i -eq 30 ]; then
          echo "⚠ Warning: Controller ServiceAccount not found, but continuing..."
        fi
        sleep 2
      done
      
      # Create Role for managing secrets and RBAC in managed-cicd namespace
      # The controller needs to:
      # 1. Read/create secrets (for github-app-secret authentication and listener config)
      # 2. Create/manage Roles and RoleBindings (for AutoscalingListener pods)
      echo "Creating Role for secret and RBAC access in $${RUNNER_NAMESPACE} namespace..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
      
      # Create RoleBinding to grant controller ServiceAccount permission to read secrets
      echo "Creating RoleBinding for controller secret access..."
      kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: arc-controller-secret-reader
  namespace: $${RUNNER_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: $${CONTROLLER_SA}
  namespace: $${NAMESPACE}
roleRef:
  kind: Role
  name: arc-controller-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF
      
      echo "✓ RBAC configured: Controller can now read secrets in $${RUNNER_NAMESPACE} namespace"
      
      echo ""
      echo "=========================================="
      echo "✓ Official ARC deployment complete"
      echo "=========================================="
      echo ""
      echo "Note: CRDs are installed immediately. Fleet can now validate"
      echo "AutoscalingRunnerSet resources (official GitHub version)."
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "=========================================="
      echo "Removing GitHub ARC Controller from POC Apps Cluster"
      echo "=========================================="
      
      export KUBECONFIG="$HOME/.kube/poc-apps.yaml"
      
      if helm list -n actions-runner-system 2>/dev/null | grep -qE "(actions-runner-controller|gha-runner-scale-set-controller)"; then
        echo "Uninstalling ARC controller..."
        helm uninstall actions-runner-controller -n actions-runner-system 2>/dev/null || true
        helm uninstall gha-runner-scale-set-controller -n actions-runner-system 2>/dev/null || true
        
        echo "Cleaning up RBAC resources..."
        kubectl delete rolebinding arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        kubectl delete role arc-controller-secret-reader -n managed-cicd 2>/dev/null || true
        
        echo "Deleting namespace..."
        kubectl delete namespace actions-runner-system --timeout=2m 2>/dev/null || true
        
        echo "✓ ARC controller removed"
      else
        echo "✓ ARC controller already removed"
      fi
    EOT
  }

  depends_on = [
    null_resource.merge_kubeconfigs,
    module.rke2_poc_apps
  ]

  triggers = {
    arc_chart_version = var.github_arc_controller_version
  }
}
