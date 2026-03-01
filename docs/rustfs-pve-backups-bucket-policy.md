# RustFS bucket policy for Proxmox VE backup (`pve-backups`)

**File:** `rustfs-pve-backups-bucket-policy.json`

Minimal bucket policy for the **pve-backups** bucket: allows ListBucket and Get/Put/Delete object (what Proxmox backup needs). No Principal — access is determined by which access key is used when attaching or using the bucket; the policy only defines allowed actions and resources.

**Apply:** Attach the policy to the bucket **pve-backups** in the RustFS console (bucket → Policy) or via `PutBucketPolicy`. Configure Proxmox backup with the RustFS endpoint, bucket `pve-backups`, and the access key ID + secret that should have access.

**See also:** [RUSTFS_PVE_BACKUPS_BUCKET.md](RUSTFS_PVE_BACKUPS_BUCKET.md) — create the bucket and attach this policy; [PROXMOX_BACKUP_RUSTFS_S3.md](PROXMOX_BACKUP_RUSTFS_S3.md) — connect the S3 endpoint in Proxmox Backup and add the datastore.
