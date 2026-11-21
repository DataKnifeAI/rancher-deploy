terraform {
  required_version = ">= 1.3"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      # Keep 0.93.x until #9 proxmox window (0.115+); ~> 0.90 would float to 0.123+.
      version = "~> 0.93.0"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    # Phase 1 of #9: bump null/local within major. rancher2→15.x and proxmox→0.115
    # and kubernetes→3.x need separate windows (refresh fixes + plan review).
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.4, < 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.1, < 3.0"
    }
  }
}

# Enable structured logging to file
# Set TF_LOG=debug or TF_LOG=trace before running terraform apply/plan
# Logs will be written to TF_LOG_PATH if set, otherwise stderr
# Example: export TF_LOG=debug TF_LOG_PATH=terraform.log
# Or configure below for automatic logging

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_user}!${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_tls_insecure

  ssh {
    agent    = true
    username = "root"
  }
}

# Rancher2 Provider - for downstream cluster management (Optional)
# Only used if register_downstream_cluster = true
# Uses API token created automatically by deploy-rancher.sh script
provider "rancher2" {
  api_url   = "https://${var.rancher_hostname}"
  token_key = var.register_downstream_cluster ? try(trimspace(file("${path.root}/../config/.rancher-api-token")), "placeholder-token") : "placeholder-token"
  insecure  = true # For self-signed certificates
}
