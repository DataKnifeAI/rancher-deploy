#!/bin/bash

# Generate Helm values file from Terraform variables
# This script reads terraform.tfvars and generates helm-values/democratic-csi-truenas.yaml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$REPO_ROOT/terraform"
VALUES_FILE="$REPO_ROOT/helm-values/democratic-csi-truenas.yaml"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Generating Helm values from Terraform variables...${NC}"
echo ""

# Check if terraform.tfvars exists
TFVARS_FILE="$TERRAFORM_DIR/terraform.tfvars"
if [ ! -f "$TFVARS_FILE" ]; then
    echo -e "${RED}Error: terraform.tfvars not found at $TFVARS_FILE${NC}"
    exit 1
fi

# Extract values from terraform.tfvars using grep and sed
# Note: This is a simple parser - assumes format: key = "value" or key = value
extract_value() {
    local key="$1"
    local default="$2"
    local value=$(grep -E "^${key}\s*=" "$TFVARS_FILE" | sed -E 's/^[^=]*=\s*["'\'']?([^"'\'']*)["'\'']?/\1/' | head -1)
    if [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Extract TrueNAS configuration
TRUENAS_HOST=$(extract_value "truenas_host" "")
TRUENAS_API_KEY=$(extract_value "truenas_api_key" "")
TRUENAS_DATASET=$(extract_value "truenas_dataset" "")
TRUENAS_USER=$(extract_value "truenas_user" "rke2")
TRUENAS_PROTOCOL=$(extract_value "truenas_protocol" "https")
TRUENAS_PORT=$(extract_value "truenas_port" "443")
TRUENAS_ALLOW_INSECURE=$(extract_value "truenas_allow_insecure" "false")
CSI_STORAGE_CLASS_NAME=$(extract_value "csi_storage_class_name" "truenas-nfs")
CSI_STORAGE_CLASS_DEFAULT=$(extract_value "csi_storage_class_default" "true")

# Validate required values
if [ -z "$TRUENAS_HOST" ] || [ -z "$TRUENAS_API_KEY" ] || [ -z "$TRUENAS_DATASET" ]; then
    echo -e "${RED}Error: Missing required TrueNAS configuration in terraform.tfvars${NC}"
    echo "Required: truenas_host, truenas_api_key, truenas_dataset"
    exit 1
fi

# Convert boolean string to YAML boolean
if [ "$TRUENAS_ALLOW_INSECURE" = "true" ] || [ "$TRUENAS_ALLOW_INSECURE" = "1" ]; then
    TRUENAS_ALLOW_INSECURE_YAML="true"
else
    TRUENAS_ALLOW_INSECURE_YAML="false"
fi

if [ "$CSI_STORAGE_CLASS_DEFAULT" = "true" ] || [ "$CSI_STORAGE_CLASS_DEFAULT" = "1" ]; then
    CSI_STORAGE_CLASS_DEFAULT_YAML="true"
else
    CSI_STORAGE_CLASS_DEFAULT_YAML="false"
fi

# Convert mountpoint path to ZFS dataset name (remove /mnt/ prefix)
# e.g., /mnt/SAS/RKE2 -> SAS/RKE2
TRUENAS_DATASET_NAME=$(echo "$TRUENAS_DATASET" | sed 's|^/mnt/||')
TRUENAS_DATASET_SNAPSHOTS="${TRUENAS_DATASET_NAME}-snapshots"

# Generate Helm values file
cat > "$VALUES_FILE" <<EOF
# Democratic CSI Helm Values for TrueNAS
# Generated from terraform.tfvars
# Host: ${TRUENAS_HOST}
# Dataset: ${TRUENAS_DATASET}
# User: ${TRUENAS_USER}
#
# This file is auto-generated. To update, edit terraform/terraform.tfvars and run:
#   ./scripts/generate-helm-values-from-tfvars.sh
#
# Usage: helm install democratic-csi democratic-csi/democratic-csi -f democratic-csi-truenas.yaml

# CSI Driver Configuration (required by chart)
csiDriver:
  name: ${CSI_STORAGE_CLASS_NAME}
  enabled: true
  attachRequired: true
  podInfoOnMount: true

# Driver Configuration
driver:
  config:
    driver: freenas-api-nfs
    # HTTP connection to TrueNAS API
    httpConnection:
      protocol: "${TRUENAS_PROTOCOL}"
      host: "${TRUENAS_HOST}"
      port: ${TRUENAS_PORT}
      apiKey: "${TRUENAS_API_KEY}"
      allowInsecure: ${TRUENAS_ALLOW_INSECURE_YAML}
    # ZFS dataset configuration
    # Note: datasetParentName should be the ZFS dataset name (e.g., "SAS/RKE2"), not the mountpoint
    # The mountpoint path (/mnt/SAS/RKE2) is used for NFS share configuration
    zfs:
      datasetParentName: "${TRUENAS_DATASET_NAME}"
      detachedSnapshotsDatasetParentName: "${TRUENAS_DATASET_SNAPSHOTS}"
    # NFS share configuration
    # Note: shareHost is used by freenas-api-nfs driver to set server in volume context
    nfs:
      shareHost: "${TRUENAS_HOST}"
      shareAlldirs: false
      shareAllowedHosts: []
      shareAllowedNetworks: []
      shareMaprootUser: root
      shareMaprootGroup: root
      shareMapallUser: ""
      shareMapallGroup: ""
# Storage Classes Configuration
# Mount options must be an array (as per democratic CSI examples)
storageClasses:
  # Default NFS storage class
  - name: ${CSI_STORAGE_CLASS_NAME}
    default: ${CSI_STORAGE_CLASS_DEFAULT_YAML}
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: "nfs"
      parentDataset: "${TRUENAS_DATASET_NAME}"
      nfsServer: "${TRUENAS_HOST}"
      # NFS version 4 recommended
      nfsVersion: "4"
    # Using default mount options (no override)

# Controller Configuration
# Note: Using "next" tag for TrueNAS 25+ compatibility (fixes SCALE detection issue)
controller:
  driver:
    image:
      tag: next
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  # Tolerations for RKE2 server nodes (control-plane and etcd taints)
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/etcd
      operator: Exists
      effect: NoExecute
    - key: CriticalAddonsOnly
      operator: Exists

# Node Configuration
# Node daemonset MUST run on all nodes (servers and workers) to handle volume mounts
node:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
  # Tolerations for RKE2 server nodes (control-plane and etcd taints)
  # Required: CSI node pods must run on server nodes to mount volumes on pods scheduled there
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/etcd
      operator: Exists
      effect: NoExecute
    - key: CriticalAddonsOnly
      operator: Exists

# RBAC
rbac:
  create: true

# Service Account
serviceAccount:
  create: true
  name: ""
EOF

echo -e "${GREEN}✓ Helm values file generated: ${VALUES_FILE}${NC}"
echo ""
echo "Configuration:"
echo "  Host: ${TRUENAS_HOST}"
echo "  Dataset: ${TRUENAS_DATASET}"
echo "  User: ${TRUENAS_USER}"
echo "  Storage Class: ${CSI_STORAGE_CLASS_NAME}"
echo "  Default: ${CSI_STORAGE_CLASS_DEFAULT_YAML}"
echo ""
echo "To install democratic-csi:"
echo "  ./scripts/install-democratic-csi.sh"
