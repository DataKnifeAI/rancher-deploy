# ingress-nginx → Traefik (RKE2)

Follows [RKE2 ingress migration](https://docs.rke2.io/reference/ingress_migration).

## Gateway API ownership (standard channel)

Apps clusters (poc/nprd/prd) run **Envoy Gateway** on Gateway API **standard** CRDs
(v1.6.x). That matches stock `rke2-traefik-crd` (same channel as rancher-manager).

Desired layout:

1. **Gateway API standard** CRDs (once per cluster) — from EG `gateway-crds-helm`
   (`crds.gatewayAPI.channel=standard`) and/or RKE2 stock `rke2-traefik-crd`.
2. **Envoy Gateway** CRDs + controller layered on top (`deploy-envoy-gateway.sh`
   installs EG CRDs only from `install.yaml`, not experimental Gateway API).
3. **Stock** `rke2-traefik-crd` for Traefik/hub CRDs (do **not** use the old
   stripped `rke2-traefik-crd-no-gateway.yaml` AddOn anymore).

`terraform/modules/envoy_gateway/deploy-envoy-gateway.sh` is the durable EG path.
Do not re-apply EG’s default `install.yaml` CRD bundle unchecked — it is
experimental and would fight standard.

Historical note: during the first Traefik cutover, apps temporarily used a
stripped Traefik CRD chart (no Gateway API) while EG still owned **experimental**
CRDs. That is obsolete after the standard-channel migration (2026-11-21).

## Files

| File | Use |
|------|-----|
| `rke2-traefik-config-phase1.yaml` | Dual: Traefik hostPorts 8000/8443 (`HelmChartConfig`) |
| `rke2-traefik-config-phase3.yaml` | Traefik-only on 80/443 + default wildcard TLS |
| `rke2-traefik-crd-no-gateway.yaml` | **Obsolete** — kept only as archive; do not install |
| `install-crd-chart-apps.sh` | **Obsolete** with standard-channel ownership |

`HelmChartConfig` for `rke2-traefik` is durable as a user manifest (e.g.
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
