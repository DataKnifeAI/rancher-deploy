terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.90"
    }
  }
}

variable "vm_name" {
  description = "VM name"
  type        = string
}

variable "vm_id" {
  description = "VM ID"
  type        = number
}

variable "cloud_image_datastore" {
  description = "Datastore ID where cloud image is already downloaded"
  type        = string
}

variable "cloud_image_file_name" {
  description = "File name of the cloud image already downloaded"
  type        = string
}

variable "datastore_id" {
  description = "Datastore ID for creating VM disks"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
}

variable "disk_size_gb" {
  description = "Disk size in GB"
  type        = number
}

variable "hostname" {
  description = "Hostname"
  type        = string
}

variable "ip_address" {
  description = "IP address with CIDR"
  type        = string
}

variable "ssh_private_key" {
  description = "Path to SSH private key for VM provisioning"
  type        = string
}

variable "gateway" {
  description = "Gateway IP"
  type        = string
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
}

variable "domain" {
  description = "Domain name"
  type        = string
}

variable "vlan_id" {
  description = "VLAN ID for network interface"
  type        = number
  default     = 0
}

variable "rke2_enabled" {
  description = "Enable RKE2 installation via cloud-init"
  type        = bool
  default     = false
}

variable "rke2_version" {
  description = "RKE2 version to install"
  type        = string
  default     = ""
}

variable "rke2_server_token" {
  description = "RKE2 server token for agents to join"
  type        = string
  default     = ""
}

variable "rke2_server_ip" {
  description = "RKE2 server IP for agents to join"
  type        = string
  default     = ""
}

variable "is_rke2_server" {
  description = "Is this the RKE2 server node"
  type        = bool
  default     = false
}
variable "rke2_is_primary" {
  description = "Whether this is a primary/first RKE2 server node in the cluster"
  type        = bool
  default     = false
}

variable "cluster_hostname" {
  description = "Cluster hostname for tls-san (e.g., manager.example.com or nprd-apps.example.com)"
  type        = string
  default     = "manager.example.com"
}

variable "cluster_primary_ip" {
  description = "Primary node IP for tls-san (e.g., 192.168.1.100 for manager or 192.168.14.110 for apps)"
  type        = string
  default     = "192.168.1.100"
}

variable "cluster_aliases" {
  description = "Additional hostname aliases for cluster tls-san (e.g., rancher.example.com)"
  type        = list(string)
  default     = []
}

variable "register_with_rancher" {
  description = "Whether to register this RKE2 cluster with Rancher Manager"
  type        = bool
  default     = false
}

variable "rancher_hostname" {
  description = "Rancher Manager hostname for downstream registration"
  type        = string
  default     = ""
}

variable "rancher_ingress_ip" {
  description = "Rancher ingress IP for /etc/hosts entry during registration"
  type        = string
  default     = ""
}

variable "rancher_registration_token" {
  description = "Token for registering with Rancher Manager"
  type        = string
  sensitive   = true
  default     = ""
}

variable "rancher_ca_checksum" {
  description = "CA certificate checksum for Rancher HTTPS verification"
  type        = string
  default     = ""
}
output "vm_id" {
  value = proxmox_virtual_environment_vm.vm.vm_id
}

output "ip_address" {
  value = var.ip_address
}

output "hostname" {
  value = var.hostname
}

# Create VM from pre-downloaded cloud image
# Image is already downloaded at root level and passed via variables
resource "proxmox_virtual_environment_vm" "vm" {
  vm_id                              = var.vm_id
  name                               = var.vm_name
  node_name                          = var.proxmox_node
  stop_on_destroy                    = true
  delete_unreferenced_disks_on_destroy = false
  purge_on_destroy                   = false

  cpu {
    cores   = var.cpu_cores
    sockets = 1
  }

  memory {
    dedicated = var.memory_mb
  }

  # Import cloud image as primary disk and expand
  disk {
    datastore_id = var.datastore_id
    import_from  = "images-import:import/${var.cloud_image_file_name}"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.disk_size_gb
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
  }

  # Enable Proxmox guest agent for better VM management
  # This allows Proxmox to get VM status, IP addresses, and perform graceful shutdowns
  agent {
    enabled = true
    trim     = true  # Enable fstrim for disk space recovery
    type     = "virtio"
  }

  initialization {
    type = "nocloud"

    user_account {
      username = "ubuntu"
      # Add SSH public key for ansible/terraform provisioning
      keys = [file("${var.ssh_private_key}.pub")]
    }

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }
  }

  # Prevent modification of import_from and disk size on existing VMs
  # Once a VM is created from an image, we can't change that import path
  # Disk size changes (shrinking) are not supported by Proxmox, so ignore them
  lifecycle {
    ignore_changes = [
      initialization,
      disk  # Ignore disk size changes to prevent shrinking attempts
    ]
  }

  # Apply RKE2 installation via provisioner if enabled
  provisioner "remote-exec" {
    inline = var.rke2_enabled ? concat(
      [
        # RKE2 installation
        "cat > /tmp/rke2-install.sh <<'RKEEOF'\n${file("${path.module}/cloud-init-rke2.sh")}\nRKEEOF",
        "chmod +x /tmp/rke2-install.sh",
        "IS_RKE2_SERVER=${var.is_rke2_server} RKE2_VERSION=${var.rke2_version} SERVER_IP=${var.rke2_server_ip} SERVER_TOKEN=${var.rke2_server_token} CLUSTER_HOSTNAME=${var.cluster_hostname} CLUSTER_PRIMARY_IP=${var.cluster_primary_ip} CLUSTER_ALIASES='${join(",", var.cluster_aliases)}' DNS_SERVERS='${join(" ", var.dns_servers)}' sudo -E bash /tmp/rke2-install.sh"
      ],
      # Add Rancher registration if this is a server node and registration is enabled
      var.register_with_rancher && var.is_rke2_server ? [
        # Add hosts entry for Rancher hostname
        "echo '${var.rancher_ingress_ip} ${var.rancher_hostname}' | sudo tee -a /etc/hosts > /dev/null",
        # Wait for RKE2 to be ready (token file should exist)
        "for i in {1..120}; do [ -f /var/lib/rancher/rke2/server/node-token ] && echo 'RKE2 ready!' && break || (echo 'Waiting for RKE2 token... $i/120' && sleep 5); done",
        # Attempt Rancher system-agent installation ONLY if credentials are available
        "if [ -n '${var.rancher_registration_token}' ] && [ -n '${var.rancher_ca_checksum}' ]; then curl -kfL https://${var.rancher_hostname}/system-agent-install.sh | sudo sh -s - --server https://${var.rancher_hostname} --label 'cattle.io/os=linux' --token ${var.rancher_registration_token} --ca-checksum ${var.rancher_ca_checksum} --etcd --controlplane --worker; else echo 'Registration credentials not available - will be done post-deployment'; fi"
      ] : []
    ) : ["echo 'RKE2 disabled, skipping installation'"]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.ssh_private_key)
      host        = split("/", var.ip_address)[0]
      timeout     = "60m"
    }
  }
}
