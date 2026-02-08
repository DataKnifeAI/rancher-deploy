# Terraform Outputs
# These outputs can be used by other tools or scripts

output "democratic_csi_config" {
  description = "Democratic CSI configuration"
  value = {
    host           = var.democratic_csi_host
    dataset        = var.democratic_csi_dataset
    user           = var.democratic_csi_user
    protocol       = var.democratic_csi_protocol
    port           = var.democratic_csi_port
    allow_insecure = var.democratic_csi_allow_insecure
    storage_class  = var.democratic_csi_storage_class_name
    is_default     = var.democratic_csi_storage_class_default
  }
  sensitive = false
}

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
