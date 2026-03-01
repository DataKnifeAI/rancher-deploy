output "bucket_name" {
  description = "Name of the S3 bucket for Rancher backups."
  value       = aws_s3_bucket.rancher_backup.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket."
  value       = aws_s3_bucket.rancher_backup.arn
}

output "region" {
  description = "AWS region of the bucket."
  value       = aws_s3_bucket.rancher_backup.region
}
