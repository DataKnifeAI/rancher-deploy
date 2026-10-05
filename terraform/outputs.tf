# Terraform Outputs
# These outputs can be used by other tools or scripts

output "truenas_csi_config" {
  description = "TrueNAS CSI configuration"
  value = {
    host           = var.truenas_csi_host
    pool           = var.truenas_csi_pool
    protocol       = var.truenas_csi_protocol
    port           = var.truenas_csi_port
    allow_insecure = var.truenas_csi_allow_insecure
    storage_class  = var.truenas_csi_storage_class_name
    is_default     = var.truenas_csi_storage_class_default
  }
  sensitive = false
}
