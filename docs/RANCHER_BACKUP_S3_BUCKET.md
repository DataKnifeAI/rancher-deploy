# S3 Bucket for Rancher Backups

Use an S3 (or S3-compatible) bucket as the Rancher Backup operator’s storage. **We use [RustFS](https://rustfs.com/)** (S3-compatible object storage). This doc covers **versioning**, **object lock**, and **quota**, and how to use RustFS or AWS for the bucket.

## Do we need versioning, object lock, quota?

| Feature | Recommended? | Why |
|--------|---------------|-----|
| **Versioning** | **Yes** | Keeps previous object versions so you can recover from overwrites or accidental deletes. Required if you use Object Lock. |
| **Object Lock** | **Optional** | WORM (write-once-read-many): objects become immutable for a retention period. Good for compliance or ransomware protection. **Once enabled, it cannot be disabled** on the bucket. |
| **Quota** | **Optional** | S3 has no per-bucket storage quota by default. Use **lifecycle rules** to expire/delete old backup versions and control size/cost, or use **AWS Budgets** for cost alerts. |

**Practical setup for Rancher backups**

- **Versioning: on** (recommended) — included in the Terraform bucket.
- **Object Lock: off** unless you need immutability/compliance; it cannot be disabled once enabled. Not included in the example Terraform; add at bucket creation if required.
- **Lifecycle (optional):** expire noncurrent versions after N days to cap size/cost — configurable via `lifecycle_expire_days` in the Terraform example (default 90).

## Create the bucket with Terraform (AWS)

An optional Terraform config is in **`terraform/environments/rancher-backup-bucket/`**. It creates an S3 bucket with versioning enabled and optional lifecycle rules.

**Prerequisites:** AWS provider credentials (e.g. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or IAM role).

```bash
cd terraform/environments/rancher-backup-bucket
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: bucket name, region, optional lifecycle
terraform init
terraform plan
terraform apply
```

Then configure the Rancher Backup operator to use this bucket (bucket name, region, folder, and credentials). See [RANCHER_BACKUP.md](RANCHER_BACKUP.md) and [Rancher backup configuration](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/backup-configuration).

## Using RustFS (our S3-compatible storage)

We use **[RustFS](https://rustfs.com/)** — S3-compatible object storage (AWS Sig V4, Apache 2.0). Create a bucket in RustFS for Rancher backups, enable versioning if supported, and point the Rancher Backup operator at it.

1. **Create a bucket** in RustFS (UI or API). Enable versioning if available.
2. **Create a credential** (access key / secret) for the Rancher Backup operator (see [RustFS docs](https://docs.rustfs.com/)).
3. **Configure the Backup CR** with a `storageLocation.s3` block:
   - `endpoint`: your RustFS endpoint (e.g. `https://rustfs.example.com` or the service URL if RustFS runs in-cluster).
   - `bucketName`: the bucket you created.
   - `credentialSecretName` / `credentialSecretNamespace`: Kubernetes secret containing S3 access key and secret (same format as for AWS/MinIO; see [Rancher backup configuration](https://ranchermanager.docs.rancher.com/reference-guides/backup-restore-configuration/backup-configuration#example-credentialsecret)).
   - Optionally `folder` and `region` if your RustFS setup uses them.

RustFS supports versioning and WORM; use them as needed for retention and compliance. See [RustFS S3 compatibility](https://docs.rustfs.com/features/s3-compatibility) and [RustFS integration](https://docs.rustfs.com/features/integration).

## Other S3-compatible (MinIO, etc.)

If you use MinIO or another S3-compatible endpoint, create the bucket there (versioning if supported) and use the same backup configuration with your endpoint and credentials. Object lock and lifecycle depend on the service.
