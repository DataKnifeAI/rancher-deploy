terraform {
  required_version = ">= 1.3"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      # Phase 3 of #9: floor at 0.115. Stay <0.118 for now (SDN/file validation breaks).
      version = "~> 0.115.0"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      # v15 tracks Rancher 2.15 API; no rancher2_* resources in this root today.
      version = "~> 15.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    # Phase 1: null/local. Phase 2: kubernetes ~> 3.0 + rancher2 ~> 15.0.
    # Phase 3: proxmox ~> 0.115.0 (further minors after plan review).
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
