# RustFS bucket policy for RKE2 backups (`rke2-backups`)

**File:** `rustfs-rke2-backups-bucket-policy.json`

Minimal bucket policy for the **rke2-backups** bucket: allows ListBucket and Get/Put/Delete object (e.g. for RKE2 etcd snapshots or backup tools writing to S3). No Principal — access is determined by which access key is used; the policy only defines allowed actions and resources.

**Apply:** Attach the policy to the bucket **rke2-backups** in the RustFS console (bucket → Policy) or via `PutBucketPolicy`. Use the same access key when configuring RKE2 backup or your backup tool to use this bucket.
