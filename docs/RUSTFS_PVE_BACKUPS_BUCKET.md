# Create RustFS bucket for Proxmox VE backups (`pve-backups`)

Create the **pve-backups** bucket in RustFS and attach the access policy so Proxmox Backup can use it. The policy allows ListBucket and Get/Put/Delete object (see [rustfs-pve-backups-bucket-policy.md](rustfs-pve-backups-bucket-policy.md)).

## Prerequisites

- RustFS is running and you have console (or API) access.
- An access key (access key ID + secret) for RustFS to use with Proxmox Backup (create one in RustFS if needed).

## 1. Create the bucket

### Option A: RustFS UI

1. Log in to the RustFS Console.
2. On the homepage, top left, select **Create Bucket**.
3. Enter bucket name: **pve-backups**.
4. Click **Create**.

### Option B: MinIO Client (mc)

If `mc` is configured with an alias for your RustFS instance (e.g. `rustfs`):

```bash
mc mb rustfs/pve-backups
# Confirm
mc ls rustfs/pve-backups
```

See [RustFS mc guide](https://docs.rustfs.com/developer/mc.html) for installation and `mc alias`.

### Option C: S3 API

Create the bucket with a PUT request to your RustFS endpoint (requires AWS Sig V4 signed headers):

```bash
PUT /pve-backups HTTP/1.1
```

Use your S3 client or a signed request; see [RustFS bucket creation](https://docs.rustfs.com/management/bucket/creation.html).

## 2. Attach the access policy

The policy grants the actions Proxmox Backup needs: `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the bucket and its objects.

1. Open **[rustfs-pve-backups-bucket-policy.json](rustfs-pve-backups-bucket-policy.json)** in this repo (or the same JSON from the repo).
2. In the RustFS Console, go to the **pve-backups** bucket → **Policy** (or equivalent).
3. Paste the policy JSON or upload it, then save.

Alternatively use the S3/RustFS API: `PutBucketPolicy` for bucket **pve-backups** with the policy document.

Policy content (for reference):

```json
{
  "ID": "",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProxmoxBackupAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "NotAction": [],
      "Resource": [
        "arn:aws:s3:::pve-backups",
        "arn:aws:s3:::pve-backups/*"
      ],
      "NotResource": [],
      "Condition": {}
    }
  ]
}
```

## 3. Next step

Configure Proxmox Backup to use this bucket: create an S3 endpoint pointing at RustFS and a datastore using bucket **pve-backups**. See [PROXMOX_BACKUP_RUSTFS_S3.md](PROXMOX_BACKUP_RUSTFS_S3.md).
