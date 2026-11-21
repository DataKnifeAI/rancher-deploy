# ingress-nginx → Traefik (RKE2)

Follows [RKE2 ingress migration](https://docs.rke2.io/reference/ingress_migration).

## Gateway API ownership (standard channel)

Apps clusters (poc/nprd/prd) run **Envoy Gateway** on Gateway API **standard** CRDs
(v1.6.x). That matches stock `rke2-traefik-crd` (same channel as rancher-manager).

Desired layout:

1. **Gateway API standard** CRDs — owned by stock **`rke2-traefik-crd`**
   (bundle v1.6.x; includes `safe-upgrades` ValidatingAdmissionPolicy).
2. **Envoy Gateway** CRDs + controller on top (`deploy-envoy-gateway.sh`
   installs EG CRDs only from `install.yaml`, not experimental Gateway API).
3. **Stock** `rke2-traefik-crd` also owns Traefik/hub CRDs.

If Gateway CRDs were first installed by EG `gateway-crds-helm` without Helm
labels, `helm-install-rke2-traefik-crd` CrashLoops until those CRDs (and the
`safe-upgrades` VAP/VAPB) are adopted:

```bash
# standard gateway.networking.k8s.io CRDs + safe-upgrades VAP/VAPB
kubectl label … app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate … meta.helm.sh/release-name=rke2-traefik-crd \
  meta.helm.sh/release-namespace=kube-system --overwrite
```

`terraform/modules/envoy_gateway/deploy-envoy-gateway.sh` is the durable EG path.
Do not re-apply EG’s default `install.yaml` CRD bundle unchecked — it is
experimental and would fight standard.

## Files

| File | Use |
|------|-----|
| `rke2-traefik-config-phase1.yaml` | Dual: Traefik hostPorts 8000/8443 (`HelmChartConfig`) |
| `rke2-traefik-config-phase3.yaml` | Traefik-only on 80/443 + default wildcard TLS |

`HelmChartConfig` for `rke2-traefik` is durable as a user manifest; it merges
values and is not overwritten by the packaged chart.

Ingresses stay on class `rke2-ingress-nginx-migration` so nginx annotations keep
working via Traefik's Ingress NGINX provider.

## Ingress → HTTPRoute (2026-11-21)

Enable `providers.kubernetesGateway` in `rke2-traefik-config-phase3.yaml`. Chart deploys
`GatewayClass/traefik` + `Gateway/kube-system/traefik-gateway` (ports 8000/8443 = host 80/443)
with wildcard `wildcard-dataknife-net-tls`. App HTTPRoutes `parentRefs` that Gateway
(`sectionName: websecure`). DNS CNAMEs to `*-apps-wk` stay unchanged.

Stoat operator emits HTTPRoutes when `spec.ingress.className` is a GatewayClass (`traefik`).

## Post-cutover gitops

Apps use HTTPRoute → `traefik-gateway` (legacy Ingress class retired) (not `nginx`) in Fleet sources:

- [gitops-mcp#21](https://github.com/DataKnifeAI/gitops-mcp/pull/21) — MCP Ingresses
- [gitops-tools#61](https://github.com/DataKnifeAI/gitops-tools/pull/61) — Authentik
- Stoat: `Stoat` CR `spec.ingress.className` (operator-managed Ingresses)
- Pulseblade: [pulseblade#8](https://github.com/DataKnifeAI/pulseblade/pull/8) — Ingress class stickiness

Default TLS is Traefik `tlsStore.default` → `wildcard-dataknife-net-tls` (phase3 HelmChartConfig).
Orphan `HelmChartConfig/rke2-ingress-nginx` removed from gitops-core ([#11](https://github.com/DataKnifeAI/gitops-core/pull/11)) and deleted live.
