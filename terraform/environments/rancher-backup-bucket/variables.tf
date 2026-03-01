variable "bucket_name" {
  description = "Name of the S3 bucket for Rancher backups (must be globally unique)."
  type        = string
}

variable "region" {
  description = "AWS region for the bucket."
  type        = string
  default     = "us-east-1"
}

variable "lifecycle_expire_days" {
  description = "Expire noncurrent (old) backup versions after this many days (0 = disable lifecycle)."
  type        = number
  default     = 90
}

variable "enable_encryption" {
  description = "Enable server-side encryption (AES256) on the bucket."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to the bucket."
  type        = map(string)
  default     = {}
}
