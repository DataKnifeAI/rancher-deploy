# Terraform Outputs
# These outputs can be used by other tools or scripts

output "truenas_config" {
  description = "TrueNAS configuration for democratic-csi"
  value = {
    host            = var.truenas_host
    dataset         = var.truenas_dataset
    user            = var.truenas_user
    protocol        = var.truenas_protocol
    port            = var.truenas_port
    allow_insecure  = var.truenas_allow_insecure
    storage_class   = var.csi_storage_class_name
    is_default      = var.csi_storage_class_default
  }
  sensitive = false
}

output "truenas_api_key" {
  description = "TrueNAS API key (sensitive)"
  value       = var.truenas_api_key
  sensitive   = true
}
