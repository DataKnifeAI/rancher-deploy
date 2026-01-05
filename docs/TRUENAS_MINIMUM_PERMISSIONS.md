# TrueNAS Minimum Permissions for Democratic CSI

## Quick Answer

**Minimum Required:**
- User with **write access** to dataset
- Ability to **create and delete** child datasets
- **API key** for that user
- **Network access** to TrueNAS API (port 443)

## Detailed Requirements

### 1. Dataset Permissions

The user needs to be able to:
- ✅ **Create** datasets under parent dataset (for PVCs)
- ✅ **Delete** datasets under parent dataset (when PVCs are deleted)
- ✅ **Read** dataset properties
- ✅ **Modify** dataset properties (optional, for quotas/compression)

**How to Grant:**
```bash
# Option 1: Ownership (simplest)
chown -R csi-user:csi-user /mnt/pool/dataset

# Option 2: ACLs (more flexible)
setfacl -R -m u:csi-user:rwx /mnt/pool/dataset
setfacl -R -d -m u:csi-user:rwx /mnt/pool/dataset
```

### 2. API Access

The user needs:
- ✅ **API key** created in TrueNAS (System → API Keys)
- ✅ **HTTPS access** to TrueNAS API (port 443)
- ✅ **Network connectivity** from RKE2 nodes to TrueNAS

**API Endpoints Used:**
- `POST /api/v2.0/pool/dataset` - Create datasets
- `DELETE /api/v2.0/pool/dataset/id/{id}` - Delete datasets
- `GET /api/v2.0/pool/dataset/id/{id}` - Read dataset info
- `GET /api/v2.0/pool/dataset` - List datasets

### 3. NFS Share Management (Optional)

**If using NFS (recommended):**
- ✅ Ability to create/delete NFS shares via API
- ⚠️ **Note:** This typically requires admin/root permissions

**Workaround:** Pre-create NFS shares manually, CSI will use them

## Setup Steps

### Step 1: Verify Dataset Permissions

```bash
# SSH to TrueNAS
ssh root@your-truenas-host

# Check current permissions
ls -ld /mnt/pool/dataset
getfacl /mnt/pool/dataset  # On TrueNAS SCALE

# Test if rke2 user can create datasets
sudo -u csi-user zfs create pool/dataset/test-permission-check
sudo -u csi-user zfs destroy pool/dataset/test-permission-check
```

### Step 2: Grant Permissions (if needed)

**If test fails, grant permissions:**

```bash
# Grant ownership
chown -R csi-user:csi-user /mnt/pool/dataset

# Or use ACLs (TrueNAS SCALE)
setfacl -R -m u:csi-user:rwx /mnt/pool/dataset
setfacl -R -d -m u:csi-user:rwx /mnt/pool/dataset
```

### Step 3: Create API Key

1. Login to TrueNAS: `https://your-truenas-host`
2. Navigate: **System → API Keys → Add**
3. User: `csi-user` (or your CSI user)
4. Generate key and save it

### Step 4: Test API Access

```bash
API_KEY="your-api-key"
TRUENAS_HOST="your-truenas-host"

# Test dataset query
curl -k -H "Authorization: Bearer ${API_KEY}" \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset/id/SAS%2FRKE2"

# Test dataset creation
curl -k -X POST \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "SAS/RKE2/test-api", "type": "FILESYSTEM"}' \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset"

# Clean up test dataset
curl -k -X DELETE \
  -H "Authorization: Bearer ${API_KEY}" \
  "https://${TRUENAS_HOST}/api/v2.0/pool/dataset/id/${DATASET_PATH}%2Ftest-api"
```

## Permission Levels Comparison

### Level 1: Minimum (Dataset Access Only)

**Permissions:**
- Write access to dataset
- Can create/delete child datasets
- API key for dataset operations

**Limitations:**
- Cannot create NFS shares via API
- May need manual NFS share setup
- Limited to dataset operations only

**Use Case:** Basic functionality, manual NFS management

### Level 2: Recommended (Dataset + NFS)

**Permissions:**
- All of Level 1, PLUS
- Ability to create/delete NFS shares
- System-level NFS management permissions

**Limitations:**
- May require admin/root-level access
- Broader permissions than strictly necessary

**Use Case:** Full automated functionality

### Level 3: Production (Dedicated User)

**Permissions:**
- Dedicated user (`csi-user`) with minimal permissions
- Ownership of dataset only
- API key with restricted scope
- Audit trail and isolation

**Benefits:**
- Security best practices
- Principle of least privilege
- Better auditability

**Use Case:** Production environments

## For Your Current Setup (rke2 user)

### Current Configuration

- **User:** `rke2`
- **Dataset:** `/mnt/SAS/RKE2`
- **Access:** Need to verify permissions

### Quick Permission Check

```bash
# Test from TrueNAS shell
sudo -u rke2 zfs list SAS/RKE2
sudo -u rke2 zfs create SAS/RKE2/test-check
sudo -u rke2 zfs destroy SAS/RKE2/test-check
```

**If successful:** ✅ User has sufficient permissions

**If fails:** Grant permissions:
```bash
chown -R csi-user:csi-user /mnt/pool/dataset
```

### API Key Requirements

The API key for `rke2` user needs:
- ✅ Access to dataset management APIs
- ✅ Ability to create/delete datasets under `/mnt/SAS/RKE2`
- ✅ Read access to dataset properties

**Note:** API keys inherit the user's permissions, so if `rke2` user can create datasets, the API key will work.

## Security Considerations

### What Democratic CSI Does

1. **Creates datasets** for each PVC (e.g., `pool/dataset/pvc-xxxxx`)
2. **Creates NFS shares** for each dataset (if using NFS)
3. **Deletes datasets** when PVCs are deleted
4. **Deletes NFS shares** when volumes are removed

### Minimum Permissions Needed

- ✅ **Dataset operations** on parent dataset and children
- ✅ **NFS share operations** (if automated, otherwise manual setup)
- ✅ **API access** to TrueNAS management interface

### What's NOT Needed

- ❌ Full pool access
- ❌ System administration
- ❌ Access to other datasets
- ❌ Shell/SSH access (API only)

## Troubleshooting Permission Issues

### Error: "Permission denied" when creating PVC

**Check:**
```bash
# Verify user can create datasets
sudo -u csi-user zfs create pool/dataset/test-permission

# Check dataset ownership
ls -ld /mnt/SAS/RKE2

# Check ACLs (TrueNAS SCALE)
getfacl /mnt/SAS/RKE2
```

**Fix:**
```bash
chown -R csi-user:csi-user /mnt/pool/dataset
```

### Error: "API authentication failed"

**Check:**
- API key is correct
- User account is active
- API key hasn't expired
- Network connectivity to TrueNAS

**Fix:**
- Create new API key
- Verify user permissions
- Test API access with curl

### Error: "Cannot create NFS share"

**Check:**
- User has NFS management permissions
- NFS service is enabled
- Network access configured

**Fix:**
- Pre-create NFS shares manually, OR
- Use root/admin API key for NFS operations

## Summary

**Minimum Required Access:**
1. ✅ Write access to `/mnt/SAS/RKE2` dataset
2. ✅ Ability to create/delete child datasets
3. ✅ API key for the user
4. ✅ Network access to TrueNAS API

**Recommended:**
- Dedicated user with ownership of dataset
- API key with dataset management permissions
- Restricted to specific dataset only

**Quick verification:**
- Verify: `sudo -u csi-user zfs create pool/dataset/test && sudo -u csi-user zfs destroy pool/dataset/test`
- If successful: ✅ Ready to use
- If fails: Run `chown -R csi-user:csi-user /mnt/pool/dataset`
