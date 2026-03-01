# Connect RustFS S3 in Proxmox Backup (PBS)

Configure Proxmox Backup Server to use the **pve-backups** bucket on RustFS (S3-compatible). You need an S3 endpoint (RustFS URL + access key) and a datastore that uses that endpoint and bucket.

**Prerequisites**

- RustFS bucket **pve-backups** exists and the access policy is attached (see [RUSTFS_PVE_BACKUPS_BUCKET.md](RUSTFS_PVE_BACKUPS_BUCKET.md)).
- An RustFS access key (ID + secret) with access to that bucket.
- PBS has a local path for the S3 datastore cache (recommended 64–128 GiB on a dedicated disk or partition).

**Note:** S3-backed datastores are tech preview in PBS. Use for evaluation or non-critical backups until the feature is stable.

---

## 1. Create the S3 endpoint (RustFS)

In Proxmox Backup, the S3 endpoint holds the RustFS URL and credentials. The bucket name is set on the datastore, not the endpoint.

### Web UI

1. Log in to the Proxmox Backup Server web interface.
2. Go to **Configuration** → **Remotes** → **S3 Endpoints** (or **Configuration** → **S3** / **S3 Endpoints**, depending on version).
3. Click **Add**.
4. Set:
   - **Name (ID):** e.g. `rustfs-pve-backups`
   - **Endpoint:** Your RustFS S3 endpoint URL (e.g. `https://rustfs.example.com` or `https://12.34.56.78:9000`). Do not include the bucket name; PBS adds it when using the datastore.
   - **Region:** Optional; use a value RustFS accepts (e.g. `us-east-1`) or leave default if RustFS does not require it.
   - **Access Key / Secret Key:** The RustFS access key ID and secret for the key that can access **pve-backups**.
   - **Path style:** Enable if RustFS expects path-style requests (bucket in path instead of hostname). Try vhost-style first (unchecked).
   - **Fingerprint:** If RustFS uses a self-signed certificate, paste the certificate fingerprint so PBS can verify the TLS connection.
5. Save.

### CLI

```bash
proxmox-backup-manager s3 endpoint create rustfs-pve-backups \
  --access-key 'YOUR_ACCESS_KEY_ID' \
  --secret-key 'YOUR_SECRET_KEY' \
  --endpoint 'https://rustfs.example.com' \
  --region us-east-1
```

If RustFS uses a self-signed cert:

```bash
proxmox-backup-manager s3 endpoint update rustfs-pve-backups --fingerprint 'SHA256:...'
```

List endpoints:

```bash
proxmox-backup-manager s3 endpoint list
```

---

## 2. Create the S3-backed datastore

The datastore uses the endpoint above and the bucket **pve-backups**. PBS also requires a **local cache** path (recommended 64–128 GiB).

### Web UI

1. Go to **Datastore** → **Add** → **Datastore**.
2. Set:
   - **Name:** e.g. `pve-backups` or `RustFS-PVE`
   - **Datastore type:** **S3** (tech preview).
   - **S3 Endpoint:** Select the endpoint you created (e.g. `rustfs-pve-backups`).
   - **Bucket:** `pve-backups`
   - **Local cache path:** e.g. `/mnt/datastore/pve-backups-cache` (must exist; use a dedicated partition or disk, 64–128 GiB recommended).
   - **GC Schedule / Prune Schedule:** e.g. daily; adjust to your retention needs.
3. Under **Prune options**, set retention (e.g. keep last N backups per interval).
4. Click **Add**.

### CLI

Ensure the cache directory exists and has enough space (e.g. dedicated disk mounted at `/mnt/datastore/pve-backups-cache`), then:

```bash
proxmox-backup-manager datastore create pve-backups /mnt/datastore/pve-backups-cache \
  --backend type=s3,client=rustfs-pve-backups,bucket=pve-backups
```

Replace `rustfs-pve-backups` with the S3 endpoint name you created.

---

## 3. Use the datastore from Proxmox VE

1. On the Proxmox VE host: **Datacenter** → **Storage** → **Add** → **Proxmox Backup Server**.
2. **ID:** e.g. `PBS-RustFS`
3. **Server:** Hostname or IP of your PBS.
4. **Username / Password:** PBS backup user (e.g. `backup@pbs`); do not use root.
5. **Datastore:** Select **pve-backups** (the S3 datastore you created).
6. **Fingerprint:** If PBS uses a self-signed certificate, paste the PBS server fingerprint.
7. (Optional) **Encryption:** Enable and store the encryption key safely for client-side encryption.
8. Add the storage; then create or edit backup jobs to use this datastore.

---

## Troubleshooting

### Failed to list buckets

PBS tests the S3 endpoint by listing buckets. If that fails, try in order:

1. **Enable path-style**  
   Edit the S3 endpoint and turn **Path style** on. Many S3-compatible backends (including RustFS in some setups) expect the bucket in the path (`/pve-backups/...`) instead of in the hostname. Path-style avoids 400 Bad Request or signature issues on the list-buckets call.

2. **Endpoint URL**  
   Use the exact RustFS S3 API URL: correct scheme (`https://`), host, and port (e.g. `:9000`). No trailing slash, no path (e.g. `https://rustfs.example.com:9000` or `https://12.34.56.78:9000`).

3. **TLS / fingerprint**  
   If RustFS uses a self-signed certificate, set the endpoint **Fingerprint** to the cert’s SHA256 fingerprint; otherwise PBS may fail before the request reaches RustFS.

4. **ListBuckets permission**  
   Our [bucket policy](rustfs-pve-backups-bucket-policy.json) only grants access to the **pve-backups** bucket. Listing all buckets is an account-level API. If RustFS requires an explicit permission for that, the access key may need an additional policy or permission that allows `s3:ListAllMyBuckets` (or equivalent). If your key is scoped only to the bucket, create the datastore via CLI and specify the bucket name; PBS may still be able to use the bucket even if the initial list-buckets test fails (depending on PBS version).

5. **Verify with AWS CLI**  
   Test the same endpoint and credentials with `aws s3 ls s3://pve-backups --endpoint-url https://...` (and `--region` if needed) to confirm RustFS accepts the requests.

---

- **Connection refused / TLS errors:** Check **Endpoint** URL (scheme, host, port), and set **Fingerprint** if RustFS uses a self-signed certificate.
- **Access denied / 403:** Confirm the access key has access to bucket **pve-backups** and that the [bucket policy](rustfs-pve-backups-bucket-policy.json) is attached in RustFS.
- **Path style:** If RustFS requires the bucket in the path, enable **Path style** on the S3 endpoint.
- **Cache:** Ensure the local cache path is writable and has enough space; PBS requires it for S3-backed datastores.

See also: [PBS storage documentation](https://pbs.proxmox.com/docs/storage.html) (S3 backend section).
