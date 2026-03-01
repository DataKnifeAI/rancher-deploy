# Connect Proxmox Backup Server (PBS) to the Proxmox VE cluster

Add PBS as backup storage on your Proxmox VE nodes so the cluster can send VM/container backups to PBS (and optionally to the S3/RustFS datastore on PBS).

## Prerequisites

- Proxmox Backup Server is installed and reachable from the PVE nodes (hostname or IP, port 8007 by default).
- A **backup user** on PBS (e.g. `backup@pbs`) with a password. Do not use `root@pam` for backups.
- At least one **datastore** on PBS (local or S3, e.g. `pve-backups` on RustFS).

## 1. Create a backup user on PBS (if you don’t have one)

On the PBS host (Web UI or CLI):

1. Log in to the PBS Web UI (e.g. `https://pbs-ip:8007`).
2. Go to **Configuration** → **Access** → **Users** (or **Datacenter** → **Permissions** → **Users**).
3. **Add** a user, e.g.:
   - **User:** `backup@pbs` (or `backup` with realm `PBS`).
   - **Password:** Set a strong password (you’ll use it on PVE when adding the storage).
4. **Permissions:** Give the user at least **DatastoreBrowser** and **DatastoreBackup** on the datastore(s) you want to use (e.g. `pve-backups`). **Admin** on the datastore is also common for backup/restore/verify.

CLI example (on PBS):

```bash
# Create user backup@pbs (realm may be pbs or Proxmox Backup Server-auth)
proxmox-backup-manager user create backup@pbs
# Set password when prompted, or:
proxmox-backup-manager user update backup@pbs --password 'your-secure-password'
# Grant permissions on datastore (adjust path and role as needed)
proxmox-backup-manager acl update /datastore/pve-backups --user backup@pbs --role DatastoreAdmin
```

## 2. Get the PBS server fingerprint (if using HTTPS with self-signed cert)

PVE needs to trust the PBS TLS certificate. If PBS uses a self-signed cert:

1. In the PBS Web UI: **Dashboard** → **Show fingerprint** (or **Node** → **Certificate**).
2. Copy the fingerprint (e.g. `SHA256:ab:cd:...`). You’ll paste it when adding the storage on PVE.

## 3. Add PBS as storage on Proxmox VE

Do this from **one** PVE node; if your cluster has a shared **Datacenter** view, adding storage there can make it available to all nodes (depending on PVE version and storage config).

### Web UI

1. In the Proxmox VE Web UI, switch to **Datacenter** (server view, top left).
2. Go to **Storage** → **Add** → **Proxmox Backup Server**.
3. Fill in:
   - **ID:** A name for this storage (e.g. `PBS-RustFS` or `PBS-backups`). Shown in backup job target list.
   - **Server:** Hostname or IP of your PBS (e.g. `pbs.dataknife.net` or `192.168.1.50`). Port 8007 is used by default for HTTPS.
   - **Username:** The PBS user (e.g. `backup@pbs`).
   - **Password:** That user’s password.
   - **Datastore:** The PBS datastore to use (e.g. `pve-backups`).
   - **Fingerprint:** Paste the PBS certificate fingerprint if you use a self-signed cert; leave empty if PBS uses a trusted CA.
   - **Namespace:** Optional; only if you use PBS namespaces.
4. Click **Add**.

The storage appears under **Datacenter** → **Storage**. You can use it in **Backup** jobs (select this storage as the target).

### CLI (one node)

```bash
# Add PBS storage (replace values)
pvesm add pbs PBS-RustFS \
  --server pbs.dataknife.net \
  --username backup@pbs \
  --password 'your-password' \
  --datastore pve-backups \
  --fingerprint 'SHA256:...'
```

List storage:

```bash
pvesm list
```

## 4. Use in backup jobs

1. **Datacenter** (or **Node**) → **Backup** → select or create a backup job.
2. Set **Storage** to the PBS storage you added (e.g. `PBS-RustFS`).
3. Choose schedule and retention; run or wait for the next run.

Backups will go to PBS and, if the datastore is S3-backed (e.g. RustFS), chunks are stored in the S3 bucket.

## Summary

| Step | Where | What |
|------|--------|------|
| 1 | PBS | Create backup user, grant permissions on datastore |
| 2 | PBS | Copy server certificate fingerprint (if self-signed) |
| 3 | PVE (Datacenter) | Storage → Add → Proxmox Backup Server (Server, User, Password, Datastore, Fingerprint) |
| 4 | PVE | Backup jobs → Storage = your PBS storage |

See also: [PROXMOX_BACKUP_RUSTFS_S3.md](PROXMOX_BACKUP_RUSTFS_S3.md) for setting up the S3 (RustFS) datastore on PBS.
