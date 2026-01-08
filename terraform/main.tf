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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = true # NEW: marks this as primary node
  rke2_server_token  = ""   # Primary generates its own token
  rke2_server_ip     = ""   # No upstream server for primary
  cluster_hostname   = var.manager_cluster_hostname
  cluster_primary_ip = var.manager_cluster_primary_ip
  cluster_aliases    = var.manager_cluster_aliases

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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = false                                                        # NEW: marks this as secondary node
  rke2_server_token  = try(trimspace(data.local_file.manager_token[0].content), "") # Token fetched locally from primary
  rke2_server_ip     = local.manager_primary_ip                                     # Primary IP
  cluster_hostname   = var.manager_cluster_hostname
  cluster_primary_ip = var.manager_cluster_primary_ip
  cluster_aliases    = var.manager_cluster_aliases

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
  vm_id                 = var.vm_id_start_apps
  proxmox_node          = var.proxmox_node
  cloud_image_datastore = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].datastore_id
  cloud_image_file_name = proxmox_virtual_environment_download_file.ubuntu_cloud_image[var.proxmox_node].file_name
  datastore_id          = var.clusters["nprd-apps"].storage

  cpu_cores    = var.clusters["nprd-apps"].cpu_cores
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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = true
  rke2_server_token  = ""
  cluster_hostname   = var.apps_cluster_hostname
  cluster_primary_ip = var.apps_cluster_primary_ip
  cluster_aliases    = var.apps_cluster_aliases
  rke2_server_ip     = ""

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
      vm_id      = var.vm_id_start_apps + i
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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.nprd_apps_token[0].content), "") # Token fetched locally from nprd-apps primary
  rke2_server_ip     = local.nprd_apps_primary_ip
  cluster_hostname   = var.apps_cluster_hostname
  cluster_primary_ip = var.apps_cluster_primary_ip
  cluster_aliases    = var.apps_cluster_aliases

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
      vm_id      = var.vm_id_start_apps + var.clusters["nprd-apps"].node_count + i - 1
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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = false # Worker nodes run in agent mode
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.nprd_apps_token[0].content), "") # Token from apps primary
  rke2_server_ip     = local.nprd_apps_primary_ip                                     # Connect to primary server
  cluster_hostname   = var.apps_cluster_hostname
  cluster_primary_ip = var.apps_cluster_primary_ip
  cluster_aliases    = var.apps_cluster_aliases

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.nprd_apps_primary,
    module.nprd_apps_additional,  # CRITICAL: Workers must wait for all control nodes to be ready
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

module "rke2_apps" {
  source = "./modules/rke2_downstream_cluster"

  cluster_name     = "nprd-apps"
  cluster_hostname = var.apps_cluster_hostname # Use FQDN instead of IP
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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = true
  rke2_server_token  = ""
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases
  rke2_server_ip     = ""

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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = true
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.prd_apps_token[0].content), "") # Token fetched locally from prd-apps primary
  rke2_server_ip     = local.prd_apps_primary_ip
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases

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
  rke2_version       = "v1.34.3+rke2r1"
  is_rke2_server     = false # Worker nodes run in agent mode
  rke2_is_primary    = false
  rke2_server_token  = try(trimspace(data.local_file.prd_apps_token[0].content), "") # Token from prd-apps primary
  rke2_server_ip     = local.prd_apps_primary_ip                                     # Connect to primary server
  cluster_hostname   = var.prd_apps_cluster_hostname
  cluster_primary_ip = var.prd_apps_cluster_primary_ip
  cluster_aliases    = var.prd_apps_cluster_aliases

  # Rancher registration - system-agent installation
  register_with_rancher      = true # Enable system-agent for automatic Rancher registration
  rancher_hostname           = var.rancher_hostname
  rancher_ingress_ip         = var.rancher_manager_ip # IP of Rancher ingress
  rancher_registration_token = ""                     # Will be obtained from Rancher API
  rancher_ca_checksum        = ""                     # Will be obtained from Rancher API

  depends_on = [
    module.prd_apps_primary,
    module.prd_apps_additional,  # CRITICAL: Workers must wait for all control nodes to be ready
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
    module.prd_apps_workers, # Always include (empty if worker_count = 0)
    module.rancher_deployment # Wait for Rancher to be deployed first
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

# ============================================================================
# FETCH DOWNSTREAM CLUSTER IDS FROM RANCHER API
# Extracts the cluster IDs after cluster objects are created
# ============================================================================

locals {
  nprd_apps_cluster_id_file = "${abspath("${path.root}/../config")}/.nprd-apps-cluster-id"
  prd_apps_cluster_id_file  = "${abspath("${path.root}/../config")}/.prd-apps-cluster-id"
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
    module.rke2_apps,
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
      
      # Merge manager and apps kubeconfigs into default config
      # Create unique users for each cluster to avoid credential conflicts
      CONFIGS_TO_MERGE=""
      [ -f "$${MANAGER_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${MANAGER_CONFIG}"
      [ -f "$${NPRD_APPS_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${NPRD_APPS_CONFIG}"
      [ -f "$${PRD_APPS_CONFIG}" ] && CONFIGS_TO_MERGE="$${CONFIGS_TO_MERGE}:$${PRD_APPS_CONFIG}"
      
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
        
        # Cleanup temp directory
        rm -rf "$${TEMP_DIR}"
        
        echo "✓ Merged kubeconfigs to $HOME/.kube/config with unique users"
      else
        echo "⚠ No kubeconfig files found to merge"
        echo "  Manager config: $${MANAGER_CONFIG} ($([ -f "$${MANAGER_CONFIG}" ] && echo 'exists' || echo 'missing'))"
        echo "  NPRD Apps config: $${NPRD_APPS_CONFIG} ($([ -f "$${NPRD_APPS_CONFIG}" ] && echo 'exists' || echo 'missing'))"
        echo "  PRD Apps config: $${PRD_APPS_CONFIG} ($([ -f "$${PRD_APPS_CONFIG}" ] && echo 'exists' || echo 'missing'))"
      fi
      
      # Verify and set context names correctly after merge
      # Kubeconfigs should already have correct context names from retrieval step,
      # but verify and fix if needed
      
      # Check if contexts exist with expected names
      MANAGER_EXISTS=$(kubectl config get-contexts rancher-manager 2>/dev/null | grep -q rancher-manager && echo "yes" || echo "no")
      NPRD_APPS_EXISTS=$(kubectl config get-contexts nprd-apps 2>/dev/null | grep -q nprd-apps && echo "yes" || echo "no")
      PRD_APPS_EXISTS=$(kubectl config get-contexts prd-apps 2>/dev/null | grep -q prd-apps && echo "yes" || echo "no")
      
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
      echo ""
      echo "Or use kubectx (if installed):"
      echo "  kubectx                    # List contexts"
      echo "  kubectx rancher-manager    # Switch to manager"
      echo "  kubectx nprd-apps          # Switch to nprd-apps"
      echo "  kubectx prd-apps           # Switch to prd-apps"
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
        
        # Remove clusters if they exist
        kubectl config delete-cluster rancher-manager 2>/dev/null || true
        kubectl config delete-cluster nprd-apps 2>/dev/null || true
        kubectl config delete-cluster prd-apps 2>/dev/null || true
        
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
      
      echo "✓ Kubeconfig cleanup complete"
    EOT
  }

  depends_on = [
    module.rancher_downstream_registration_nprd_apps,
    module.rancher_downstream_registration_prd_apps
  ]
}

# ============================================================================
# DEMOCRATIC CSI STORAGE CLASS DEPLOYMENT
# Installs democratic-csi with TrueNAS and creates storage class
# Runs at the end of the plan after all clusters are ready
# Deploys to both nprd-apps and prd-apps clusters
# ============================================================================

resource "null_resource" "deploy_democratic_csi_nprd_apps" {
  count = var.truenas_host != "" && var.truenas_api_key != "" ? 1 : 0

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
      if kubectl get storageclass ${var.csi_storage_class_name} &>/dev/null; then
        echo "✓ Storage class '${var.csi_storage_class_name}' created"
        
        # Check if it's default
        IS_DEFAULT=$(kubectl get storageclass ${var.csi_storage_class_name} -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
        if [ "$IS_DEFAULT" = "true" ]; then
          echo "✓ Storage class '${var.csi_storage_class_name}' is set as default"
        elif [ "${var.csi_storage_class_default}" = "true" ]; then
          echo "Setting storage class as default..."
          # Remove default from any existing default storage class
          EXISTING_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "${var.csi_storage_class_name}" ]; then
            echo "  Removing default from: $EXISTING_DEFAULT"
            kubectl patch storageclass "$EXISTING_DEFAULT" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}' || true
          fi
          # Set as default
          kubectl patch storageclass ${var.csi_storage_class_name} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}' || true
          echo "✓ Storage class set as default"
        fi
      else
        echo "⚠ Storage class '${var.csi_storage_class_name}' not found"
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
    module.rke2_apps
  ]

  triggers = {
    truenas_host              = var.truenas_host
    truenas_api_key           = sha256(var.truenas_api_key) # Use hash to avoid storing secret
    truenas_dataset           = var.truenas_dataset
    csi_storage_class_name    = var.csi_storage_class_name
    csi_storage_class_default = var.csi_storage_class_default
    helm_values_file          = filemd5("${path.root}/../scripts/generate-helm-values-from-tfvars.sh")
  }
}

resource "null_resource" "deploy_democratic_csi_prd_apps" {
  count = var.truenas_host != "" && var.truenas_api_key != "" ? 1 : 0

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
      if kubectl get storageclass ${var.csi_storage_class_name} &>/dev/null; then
        echo "✓ Storage class '${var.csi_storage_class_name}' created"
        
        # Check if it's default
        IS_DEFAULT=$(kubectl get storageclass ${var.csi_storage_class_name} -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")
        if [ "$IS_DEFAULT" = "true" ]; then
          echo "✓ Storage class '${var.csi_storage_class_name}' is set as default"
        elif [ "${var.csi_storage_class_default}" = "true" ]; then
          echo "Setting storage class as default..."
          # Remove default from any existing default storage class
          EXISTING_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$EXISTING_DEFAULT" ] && [ "$EXISTING_DEFAULT" != "${var.csi_storage_class_name}" ]; then
            echo "  Removing default from: $EXISTING_DEFAULT"
            kubectl patch storageclass "$EXISTING_DEFAULT" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}' || true
          fi
          # Set as default
          kubectl patch storageclass ${var.csi_storage_class_name} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}' || true
          echo "✓ Storage class set as default"
        fi
      else
        echo "⚠ Storage class '${var.csi_storage_class_name}' not found"
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
    truenas_host              = var.truenas_host
    truenas_api_key           = sha256(var.truenas_api_key) # Use hash to avoid storing secret
    truenas_dataset           = var.truenas_dataset
    csi_storage_class_name    = var.csi_storage_class_name
    csi_storage_class_default = var.csi_storage_class_default
    helm_values_file          = filemd5("${path.root}/../scripts/generate-helm-values-from-tfvars.sh")
  }
}

# ============================================================================
# CLOUDNATIVEPG OPERATOR DEPLOYMENT
# Installs CloudNativePG operator for PostgreSQL management
# Deploys to both nprd-apps and prd-apps clusters
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
      echo "Installing CloudNativePG operator..."
      CNPG_VERSION="1.28.0"
      CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-${CNPG_VERSION}.yaml"
      
      # Apply the manifest with server-side apply
      kubectl apply --server-side -f "$CNPG_MANIFEST_URL" || {
        echo "⚠ Server-side apply failed, trying regular apply..."
        kubectl apply -f "$CNPG_MANIFEST_URL"
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
      
      export KUBECONFIG="$HOME/.kube/nprd-apps.yaml"
      
      if kubectl get namespace cnpg-system &>/dev/null; then
        echo "Removing CloudNativePG operator..."
        CNPG_VERSION="1.28.0"
        CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-${CNPG_VERSION}.yaml"
        kubectl delete -f "$CNPG_MANIFEST_URL" --ignore-not-found=true || true
        
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
    module.rke2_apps
  ]

  triggers = {
    cnpg_version = "1.28.0"
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
      echo "Installing CloudNativePG operator..."
      CNPG_VERSION="1.28.0"
      CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-${CNPG_VERSION}.yaml"
      
      # Apply the manifest with server-side apply
      kubectl apply --server-side -f "$CNPG_MANIFEST_URL" || {
        echo "⚠ Server-side apply failed, trying regular apply..."
        kubectl apply -f "$CNPG_MANIFEST_URL"
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
      
      export KUBECONFIG="$HOME/.kube/prd-apps.yaml"
      
      if kubectl get namespace cnpg-system &>/dev/null; then
        echo "Removing CloudNativePG operator..."
        CNPG_VERSION="1.28.0"
        CNPG_MANIFEST_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-${CNPG_VERSION}.yaml"
        kubectl delete -f "$CNPG_MANIFEST_URL" --ignore-not-found=true || true
        
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
    cnpg_version = "1.28.0"
  }
}
