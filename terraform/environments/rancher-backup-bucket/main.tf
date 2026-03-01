# Optional: S3 bucket for Rancher Backup operator storage.
# Run from this directory: terraform init && terraform apply
# Requires AWS credentials (env or ~/.aws/credentials).

resource "aws_s3_bucket" "rancher_backup" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    Purpose = "rancher-backup"
  })
}

resource "aws_s3_bucket_versioning" "rancher_backup" {
  bucket = aws_s3_bucket.rancher_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Optional: expire old backup versions to control size/cost
resource "aws_s3_bucket_lifecycle_configuration" "rancher_backup" {
  count  = var.lifecycle_expire_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.rancher_backup.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.lifecycle_expire_days
    }
  }
}

# Block public access (recommended for backup buckets)
resource "aws_s3_bucket_public_access_block" "rancher_backup" {
  bucket = aws_s3_bucket.rancher_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optional: server-side encryption (recommended)
resource "aws_s3_bucket_server_side_encryption_configuration" "rancher_backup" {
  count  = var.enable_encryption ? 1 : 0
  bucket = aws_s3_bucket.rancher_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
