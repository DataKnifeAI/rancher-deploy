# TrueNAS CSI Migration – Workload Inventory & Priority

All workloads below use **Democratic CSI** (`truenas-nfs`). Migrate to **TrueNAS CSI** (`truenas-csi-nfs`) in the order shown.

---

## Summary

| Cluster   | PVCs (truenas-nfs) | Total size | Priority order |
|-----------|--------------------|------------|----------------|
| nprd-apps | 16                 | ~1.2 TB    | 1–7            |
| prd-apps  | 14                 | ~720 Gi    | 8–12           |
| poc-apps  | 2                  | 220 Gi     | 13–14          |

**Note:** `csi-test` on prd-apps already uses `truenas-csi-nfs`; no migration needed.

---

## Priority 1: Critical infrastructure (nprd-apps)

Migrate first; these underpin monitoring, logging, and registry.

| # | Namespace      | PVC(s) | Size    | Workload                 | Complexity |
|---|----------------|--------|---------|--------------------------|------------|
| 1 | managed-syslog | prometheus-prometheus-kube-prometheus-prometheus-db-prometheus-prometheus-kube-prometheus-prometheus-0 | 200Gi | Prometheus metrics       | StatefulSet |
| 2 | managed-syslog | alertmanager-prometheus-kube-prometheus-alertmanager-db-alertmanager-prometheus-kube-prometheus-alertmanager-0 | 20Gi | Alertmanager             | StatefulSet |
| 3 | managed-tools  | harbor-registry, harbor-postgresql-1, harbor-postgresql-2, harbor-redis, harbor-trivy, harbor-jobservice | 405Gi + 40Gi + 20Gi + 20Gi + 5Gi + 1Gi | Harbor (registry, DB, cache) | Multiple StatefulSets/Deployments |
| 4 | managed-syslog | grafana          | 10Gi  | Grafana dashboards       | Deployment  |
| 5 | managed-syslog | data-loki-* (index-gateway, ingester x3, ruler) | 50Gi | Loki logging             | StatefulSets |
| 6 | managed-syslog | export-0-loki-minio-0, export-1-loki-minio-0 | 500Gi | Loki MinIO storage       | StatefulSets |
| 7 | default        | high-command-api-db | 1Gi | High-command API DB      | Deployment  |

---

## Priority 2: Production application databases (prd-apps)

| # | Namespace    | PVC(s) | Size | Workload            | Complexity      |
|---|--------------|--------|------|---------------------|-----------------|
| 8 | high-command | high-command-postgres-1, 2, 3 | 30Gi | High-command Postgres | StatefulSet (3 replicas) |
| 9 | coder        | coder-postgres-1, 2, 3 | 30Gi | Coder Postgres        | StatefulSet (3 replicas) |

---

## Priority 3: AI/ML workloads (prd-apps)

| # | Namespace | PVC(s) | Size  | Workload                      | Complexity |
|---|-----------|--------|-------|-------------------------------|------------|
| 10 | freya    | comfyui-input, comfyui-models, comfyui-output, swarmui-* | 500Gi | ComfyUI & SwarmUI models/data | Multiple Deployments |
| 11 | coder-workspaces | coder-*-home | 50Gi | Coder user workspaces | Dynamic PVCs |

---

## Priority 4: POC / test (poc-apps)

| # | Namespace      | PVC(s) | Size | Workload           | Complexity  |
|---|----------------|--------|------|--------------------|-------------|
| 12 | managed-syslog | prometheus-prometheus-kube-prometheus-prometheus-db-prometheus-prometheus-kube-prometheus-prometheus-0 | 200Gi | Prometheus         | StatefulSet |
| 13 | managed-syslog | alertmanager-prometheus-kube-prometheus-alertmanager-db-alertmanager-prometheus-kube-prometheus-alertmanager-0 | 20Gi | Alertmanager       | StatefulSet |

---

## Migration order

1. **poc-apps first** – Smallest set (2 PVCs), good for validating the process.
2. **nprd-apps** – Harbor and monitoring; plan for maintenance.
3. **prd-apps** – DBs and AI workloads; do during low-traffic windows.

---

## Per-workload migration notes

| Workload type          | Approach                                                                 |
|------------------------|--------------------------------------------------------------------------|
| **StatefulSet**        | New StatefulSet + new template (truenas-csi-nfs) → migrate data → replace old. |
| **Deployment**         | New PVC → migration pod → update Deployment → delete old PVC.           |
| **Harbor**             | Helm upgrade with new values; migrate each component’s PVC individually. |
| **Coder workspaces**   | Per-workspace; each gets a new PVC when migrated.                       |

---

## Quick reference: PVC count by cluster

```
nprd-apps: 16 PVCs, ~1.2 TB
prd-apps:  14 PVCs, ~720 Gi (excl. csi-test)
poc-apps:  2 PVCs,  220 Gi
```
