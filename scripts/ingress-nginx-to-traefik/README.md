# ingress-nginx → Traefik (RKE2)

Follows [RKE2 ingress migration](https://docs.rke2.io/reference/ingress_migration) with a lab-specific CRD tweak.

## Gateway API ownership

Apps clusters (poc/nprd/prd) run **Envoy Gateway** on Gateway API **experimental** CRDs.
Stock `rke2-traefik-crd` tries to install Gateway API **standard** and fails (or would steal ownership).

Use `rke2-traefik-crd-no-gateway.yaml` on apps clusters (traefik.io + hub CRDs only).
**rancher-manager** has no EG — use the stock RKE2 Traefik CRD chart.

## Files

| File | Use |
|------|-----|
| `rke2-traefik-crd-no-gateway.yaml` | Apps clusters only |
| `rke2-traefik-config-phase1.yaml` | Dual: Traefik hostPorts 8000/8443 |
| `rke2-traefik-config-phase3.yaml` | Traefik-only on 80/443 + default wildcard TLS |

Ingresses stay on class `rke2-ingress-nginx-migration` so nginx annotations keep working via Traefik's Ingress NGINX provider.

## Post-cutover gitops

Keep Ingress `ingressClassName: rke2-ingress-nginx-migration` (not `nginx`) in Fleet sources:

- [gitops-mcp#21](https://github.com/DataKnifeAI/gitops-mcp/pull/21) — MCP Ingresses
- [gitops-tools#61](https://github.com/DataKnifeAI/gitops-tools/pull/61) — Authentik
- Stoat: `Stoat` CR `spec.ingress.className` (operator-managed Ingresses)
- Pulseblade: update `deploy/k8s` Ingress manifests on next apply

Default TLS is Traefik `tlsStore.default` → `wildcard-dataknife-net-tls` (phase3 HelmChartConfig).
Orphan `HelmChartConfig/rke2-ingress-nginx` and gitops-core nginx default-cert overlays are inert once the nginx chart is gone; clean up when convenient.
