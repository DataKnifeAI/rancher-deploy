# ingress-nginx → Traefik (RKE2)

Follows [RKE2 ingress migration](https://docs.rke2.io/reference/ingress_migration) with a lab-specific CRD tweak.

## Gateway API ownership

Apps clusters (poc/nprd/prd) run **Envoy Gateway** on Gateway API **experimental** CRDs.
Stock `rke2-traefik-crd` tries to install Gateway API **standard** and fails (or would steal ownership).

**rancher-manager** has no EG — use the stock RKE2 Traefik CRD chart (no skip, no custom AddOn).

### Durable install on apps clusters (required)

RKE2 [rewrites packaged manifests](https://docs.rke2.io/install/packaged_components) under
`/var/lib/rancher/rke2/server/manifests/` on every `rke2-server` start. Editing or
`kubectl apply`-ing a HelmChart named `rke2-traefik-crd` is **not** durable — the next
CP restart restores the stock chart (Gateway API CRDs included).

On **every control-plane node** (keep files in sync; RKE2 does not replicate AddOns):

1. Skip the packaged chart so it is never applied:
   `touch /var/lib/rancher/rke2/server/manifests/rke2-traefik-crd.yaml.skip`
2. Install this repo’s stripped chart as a **user** AddOn (non-stock filename):
   copy `rke2-traefik-crd-no-gateway.yaml` →  
   `/var/lib/rancher/rke2/server/manifests/dataknife-rke2-traefik-crd.yaml`

The HelmChart object is named `dataknife-rke2-traefik-crd` (not the packaged name) so it
does not fight the stock AddOn for objectset ownership. Traefik only needs the CRDs in
the API; the HelmChart name does not matter.

Helper: `./install-crd-chart-apps.sh <ssh_key> <cp-ip> [<cp-ip>...]`

After adding `.skip` on a cluster that already ran stock `rke2-traefik-crd`, either wait
for a clean apply from the user AddOn or delete the old HelmChart/Addon once, then
confirm `kubectl -n kube-system get helmchart` shows `dataknife-rke2-traefik-crd` and
Gateway API CRDs remain the EG experimental set.

Rancher-provisioned alternative: put the same YAML in **Cluster Configuration → Additional
Manifests**, plus ensure `.skip` exists on CPs (or disable the packaged AddOn via cluster
config if you manage disables there).

## Files

| File | Use |
|------|-----|
| `rke2-traefik-crd-no-gateway.yaml` | Apps CPs only — user AddOn (see above) |
| `install-crd-chart-apps.sh` | SCP + `.skip` onto apps control-plane nodes |
| `rke2-traefik-config-phase1.yaml` | Dual: Traefik hostPorts 8000/8443 (`HelmChartConfig`, durable as user AddOn) |
| `rke2-traefik-config-phase3.yaml` | Traefik-only on 80/443 + default wildcard TLS |

`HelmChartConfig` for `rke2-traefik` **is** durable when placed as a user manifest (e.g.
`rke2-traefik-config.yaml`); it merges values and is not overwritten by the packaged chart.

Ingresses stay on class `rke2-ingress-nginx-migration` so nginx annotations keep working via Traefik's Ingress NGINX provider.

## Post-cutover gitops

Keep Ingress `ingressClassName: rke2-ingress-nginx-migration` (not `nginx`) in Fleet sources:

- [gitops-mcp#21](https://github.com/DataKnifeAI/gitops-mcp/pull/21) — MCP Ingresses
- [gitops-tools#61](https://github.com/DataKnifeAI/gitops-tools/pull/61) — Authentik
- Stoat: `Stoat` CR `spec.ingress.className` (operator-managed Ingresses)
- Pulseblade: update `deploy/k8s` Ingress manifests on next apply

Default TLS is Traefik `tlsStore.default` → `wildcard-dataknife-net-tls` (phase3 HelmChartConfig).
Orphan `HelmChartConfig/rke2-ingress-nginx` and gitops-core nginx default-cert overlays are inert once the nginx chart is gone; clean up when convenient.
