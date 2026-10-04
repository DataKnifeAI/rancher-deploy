# Cluster access and SSO (Authentik → Rancher → kubectl)

How people and tools log in to Rancher and the RKE2 clusters, and what to do when that breaks.

**Last verified:** 2026-10-04 — Rancher `v2.15.0`, RKE2 `v1.36.2+rke2r1` on all clusters, Rancher CLI `v2.15.2`, Authentik `2026.8.3`.

Kubeconfigs no longer embed long-lived Rancher tokens. `kubectl` calls the Rancher CLI (`rancher token`) as an exec credential plugin, the CLI logs you in through Authentik (SAML) and caches a token. Break-glass paths do not depend on Authentik.

## Daily use (TL;DR)

```bash
kubectl --context prd-apps get pods          # SSO; first call prints a login link
kubectl --context prd-apps-local get nodes   # break-glass: Rancher local user (password prompt, needs a TTY)
rancher token delete all                     # forget cached tokens (forces a fresh login)
```

- First `kubectl` call after the cache is empty prints `Login to Rancher Server at https://rancher.dataknife.net/dashboard/auth/login?cli=true&requestId=...`. Open it, finish the Authentik login, and the CLI picks up the token by polling — no TTY needed after the click.
- One login covers **all** clusters (the cache entry is not cluster-scoped) and lasts up to 90 days.
- Rancher UI: <https://rancher.dataknife.net> → the SAML button (provider is named **Keycloak**, it is Authentik behind it). Fallback: **Log in with Local User** (`admin`).
- Use `--context` (or `kubectx`) against `~/.kube/config`. Do not `export KUBECONFIG=~/.kube/<cluster>.yaml` for daily work — those files are the Terraform/break-glass kubeconfigs (see [Fallback](#fallback-and-break-glass)).

## Architecture

```
 Browser / kubectl
        │
        ▼
 Authentik  https://auth.dataknife.net      (prd-apps, ns authentik; SAML IdP)
        │  signed SAML response + assertion (HTTP-POST binding)
        ▼
 Rancher v2.15.0  https://rancher.dataknife.net   (manager cluster "local")
   auth providers: keycloak (SAML → Authentik), local
        │  kubeconfig token (TTL ≤ 90 days)
        ▼
 rancher token  (kubectl exec credential plugin; cache: ~/.rancher/cli2.json)
        │
        ▼
 kubectl → https://rancher.dataknife.net/k8s/clusters/<cluster-id> → cluster
```

| Context | Rancher cluster | ID | Notes |
|---------|-----------------|----|-------|
| `local` | rancher-manager | `local` | Manager (Rancher itself) |
| `nprd-apps` | nprd-apps | `c-wnfsj` | |
| `prd-apps` | prd-apps | `c-ps6zm` | Default namespace `game-servers` (preserved by the setup script) |
| `poc-apps` | poc-apps | `c-k7zls` | Upgrade canary |

Each context has a `<context>-local` twin (e.g. `prd-apps-local`; the manager one is `local-local`) that always uses the Rancher **local** provider.

Apps are deployed by Fleet GitRepos in `fleet-default` from `DataKnifeAI/gitops-core`, `gitops-tools`, `gitops-dev`, and `gitops-mcp` — prefer a Git change over `kubectl apply` for anything Fleet owns.

**Dependency loop to remember:** Authentik runs on **prd-apps**, which you reach through Rancher. If prd-apps, its ingress, or Authentik is down, SSO is down — use the local-user or RKE2-admin paths below.

## First-time setup (new workstation or Coder workspace)

Prerequisites: `kubectl`, `curl`, `jq`; browser access to `rancher.dataknife.net` and `auth.dataknife.net`; `~/.local/bin` on `PATH`.

The script needs a working Rancher API token **once**, only to look up your user ID and the cluster list. It tries, in order: `$RANCHER_TOKEN`, `rancher_api_token` in `terraform/terraform.tfvars`, a token in an existing `~/.kube/config` context that points at Rancher, then the Rancher CLI cache. On a fresh machine, create a short-lived key in the Rancher UI (avatar → **Account & API Keys**), export it, and delete the key afterwards.

```bash
git clone https://github.com/DataKnifeAI/rancher-deploy.git && cd rancher-deploy

export RANCHER_TOKEN='token-xxxxx:...'   # only if none of the sources above exist
./scripts/setup-rancher-kubeconfig.sh --server rancher.dataknife.net \
  --install-cli --merge --auth-provider keyCloakProvider --break-glass
unset RANCHER_TOKEN

kubectl --context prd-apps get nodes     # click the printed link once
```

`--server` can be omitted when `terraform/terraform.tfvars` has `rancher_hostname`. `make rancher-kubeconfig` runs `--install-cli --merge`; add the SSO flags with `make rancher-kubeconfig RANCHER_KUBECONFIG_ARGS="--auth-provider keyCloakProvider --break-glass"`.

| Flag | Effect |
|------|--------|
| `--server HOST` | Rancher hostname (default: `rancher_hostname` from tfvars) |
| `--output FILE` | Kubeconfig to write (default `~/.kube/rancher.yaml`) |
| `--merge` | Merge into `~/.kube/config`; backup at `~/.kube/config.bak-<timestamp>`; the new file wins, so same-named contexts/users/clusters are **replaced** (old names such as `rancher-manager` are left alone) |
| `--install-cli` | Install the latest Rancher CLI into `~/.local/bin/rancher` if missing |
| `--auth-provider NAME` | `keyCloakProvider` (SAML, prints a link) or `localProvider` (password). Needed now that two providers are enabled, otherwise `rancher token` asks which one |
| `--break-glass` | Also write `<cluster>-local` contexts pinned to `localProvider` |
| `--disable-ui-tokens` | Set `kubeconfig-generate-token=false` (already done globally) |

Each generated user runs:

```
rancher token --server=rancher.dataknife.net --user=user-f4528 --auth-provider=keyCloakProvider   # interactiveMode: IfAvailable
```

**Coder workspaces:** the `dkai-agent` and `dkai-hermes` templates install the Rancher CLI and persist `~/.rancher` on the tool-config PVC, so a login survives restarts. `dkai-arch`, `dkai-dev`, and `kubernetes` do not — run the script with `--install-cli` and expect to log in again after a rebuild. (Templates live outside this repo.)

**Headless / SSH sessions:** the SSO link can be opened in any browser; the CLI on the remote host keeps polling. Only the `-local` password prompt needs an interactive terminal.

## Rancher SAML configuration reference

Configured under **Users & Authentication → Auth Provider → Keycloak (SAML)**. Live object: `kubectl --context local get authconfigs.management.cattle.io keycloak -o yaml`.

| Rancher field | Value |
|---------------|-------|
| Provider | Keycloak (SAML) — authconfig `keycloak`; CLI name `keyCloakProvider` |
| Display Name Field | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` |
| User Name Field | `http://schemas.goauthentik.io/2021/02/saml/username` |
| UID Field | `http://schemas.goauthentik.io/2021/02/saml/uid` |
| Groups Field | `http://schemas.xmlsoap.org/claims/Group` |
| Rancher API Host | `https://rancher.dataknife.net` |
| SP entity ID / audience | `https://rancher.dataknife.net/v1-saml/keycloak/saml/metadata` |
| ACS URL | `https://rancher.dataknife.net/v1-saml/keycloak/saml/acs` |
| IdP metadata | Downloaded from `https://auth.dataknife.net/api/v3/providers/saml/1/metadata/?download` (Rancher stores the XML) |
| SP certificate / key | 10-year self-signed (`CN=rancher.dataknife.net`, expires 2036-10-01). Kept **out of git** at `~/.config/rancher-saml/sp.crt` / `sp.key` (with `authentik-idp-metadata.xml`). Rancher stores the key in Secret `cattle-global-data/keycloakconfig-spkey` |
| Site access | See below |

**Site access.** The intended mode is `unrestricted` (any Authentik user can log in and gets Rancher's new-user default global role). On 2026-10-04 the live authconfig reported `accessMode: required` with only `keycloak_user://4` (akadmin) allowed — i.e. only akadmin (plus local users) can log in via SSO. Check and change it in the UI (**Site Access**) or inspect with:

```bash
kubectl --context local get authconfigs.management.cattle.io keycloak -o jsonpath='{.accessMode} {.allowedPrincipalIds}{"\n"}'
```

`restricted` = allowed principals plus anyone who is a member of a cluster/project; `required` = allowed principals only.

**Admin linking.** The Rancher local `admin` (`user-f4528`) carries both `local://user-f4528` and `keycloak_user://4`, so logging in as Authentik `akadmin` *is* the Rancher admin. The link was created when the admin clicked **Enable** in the UI.

**Gotchas**

- After saving, the form shows the SP **private key empty**. When editing or re-enabling, supply it again (**Read from a file** → `~/.config/rancher-saml/sp.key`) or the save fails.
- **Enable** must be clicked in a browser: the test-and-enable state lives in browser cookies, so a redirect URL generated with `curl` cannot be completed.
- Allow pop-ups for `rancher.dataknife.net` (the SAML test opens one).
- SAML has no user search API: a user or group shows up in Rancher's member pickers only after someone with that principal has logged in once. Have new users log in, then grant cluster/project roles (with `required`, add them or their Authentik group to Site Access first).

**Regenerating the SP certificate** (only if lost or near expiry; then re-upload cert + key in Rancher and re-enable):

```bash
mkdir -p ~/.config/rancher-saml && cd ~/.config/rancher-saml
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout sp.key -out sp.crt -subj "/CN=rancher.dataknife.net/O=DataKnife"
chmod 600 sp.key
```

## Authentik

| Item | Value |
|------|-------|
| URL | <https://auth.dataknife.net> |
| Where | prd-apps, namespace `authentik` |
| Deployed by | Fleet, `DataKnifeAI/gitops-tools` → `authentik/overlays/prd-apps` (chart `2026.8.3`) |
| Shape | 2 server replicas + PDB, 1 worker, CNPG cluster `authentik-postgres` (3 instances) |
| Ingress | ingress-nginx with the default `*.dataknife.net` wildcard certificate |
| Out-of-band secrets | `authentik-env` (secret key, DB password, bootstrap email/password/token) and `authentik-postgres-credentials` — see `secrets/authentik/README.md` in gitops-tools |
| Bootstrap admin | `akadmin` |

```bash
# akadmin bootstrap password
kubectl --context prd-apps -n authentik get secret authentik-env \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d; echo

# Locked out of Authentik: one-time recovery link (argument = validity in minutes)
kubectl --context prd-apps -n authentik exec deploy/authentik-server -- ak create_recovery_key 10 akadmin

# Or reset the password directly
kubectl --context prd-apps -n authentik exec -it deploy/authentik-server -- ak changepassword akadmin
```

If SSO is unavailable, run these with `--context prd-apps-local` or `--kubeconfig ~/.kube/prd-apps.yaml` (RKE2 admin).

**SAML provider for Rancher**

| Authentik setting | Value |
|-------------------|-------|
| Provider | `Rancher` (SAML, pk `1`) |
| Application | slug `rancher` |
| ACS URL | `https://rancher.dataknife.net/v1-saml/keycloak/saml/acs` |
| Audience / issuer for SP | `https://rancher.dataknife.net/v1-saml/keycloak/saml/metadata` |
| Binding | POST |
| Signing | Assertion **and** response signed with `authentik Self-signed Certificate` (expires **2027-10-04**) |
| Authorization flow | implicit consent |
| Metadata | `https://auth.dataknife.net/api/v3/providers/saml/1/metadata/?download` |

## Global token settings

| Setting | Value | Default | Why |
|---------|-------|---------|-----|
| `kubeconfig-generate-token` | `false` | `true` | UI **Download KubeConfig** now emits exec/CLI kubeconfigs — no 30-day tokens sitting in files |
| `kubeconfig-default-token-ttl-minutes` | `129600` (90 d) | `43200` | Matches the max; applies to kubeconfig tokens Rancher generates (CLI-issued ones were observed at 90 days too) |
| `auth-token-max-ttl-minutes` | `129600` (90 d) | `129600` | Caps **all** API and kubeconfig tokens, including requests for `ttl: 0` |
| `auth-user-session-ttl-minutes` | `960` (16 h) | `960` | UI session length (unchanged) |

```bash
for s in kubeconfig-generate-token kubeconfig-default-token-ttl-minutes auth-token-max-ttl-minutes auth-user-session-ttl-minutes; do
  printf '%s=%s\n' "$s" "$(kubectl --context local get settings.management.cattle.io "$s" -o jsonpath='{.value}')"
done   # empty value = using default
```

Rancher v2.14+ deprecates v3 tokens (`tokens.management.cattle.io`) in favour of `tokens.ext.cattle.io`; scripts here still use `/v3/tokens`. See [Rancher: API tokens](https://ranchermanager.docs.rancher.com/api/api-tokens).

## Fallback and break-glass

Use the first layer that works:

| # | Path | Depends on | How |
|---|------|------------|-----|
| 1 | Rancher UI local login | Rancher | **Log in with Local User** → `admin` |
| 2 | `<cluster>-local` kubectl contexts | Rancher | `kubectl --context prd-apps-local get nodes`; password prompt (needs a TTY) |
| 3 | RKE2 admin kubeconfigs | SSH or existing files only | `kubectl --kubeconfig ~/.kube/prd-apps.yaml get nodes` |
| 4 | Authentik recovery key | prd-apps API (any path above) | `ak create_recovery_key` (see [Authentik](#authentik)) |

**RKE2 admin kubeconfigs (layer 3).** Terraform (`get_kubeconfig` in the `rke2_*_cluster` modules) copies `/etc/rancher/rke2/rke2.yaml` over SSH to `~/.kube/rancher-manager.yaml`, `nprd-apps.yaml`, `prd-apps.yaml`, `poc-apps.yaml`, rewritten to `<cluster>_cluster_hostname:6443`, and `merge_kubeconfigs` merges them into `~/.kube/config`. They are `system:masters` client certs: independent of Rancher and Authentik, valid about a year, and **cluster-admin** — keep them for break-glass, drains during upgrades, and automation only.

These paths are easy to overwrite with UI-downloaded Rancher kubeconfigs (that happened on the main workstation). Check, and re-pull if the server is `rancher.dataknife.net/k8s/clusters/...`:

```bash
for f in rancher-manager nprd-apps prd-apps poc-apps; do
  printf '%-16s %s\n' "$f" "$(kubectl --kubeconfig ~/.kube/$f.yaml config view -o jsonpath='{.clusters[0].cluster.server}')"
done

# Re-pull one cluster (same rewrite Terraform does); node = any server of that cluster
CLUSTER=prd-apps HOST=prd-apps.dataknife.net NODE=<prd-apps-1 IP>
ssh -i .keys/id_rsa ubuntu@"$NODE" 'sudo cat /etc/rancher/rke2/rke2.yaml' \
  | sed "s/127.0.0.1/$HOST/; s/: default\$/: $CLUSTER/" > ~/.kube/$CLUSTER.yaml
chmod 600 ~/.kube/$CLUSTER.yaml
kubectl --kubeconfig ~/.kube/$CLUSTER.yaml get nodes
```

Terraform add-on steps also read `~/.kube/<cluster>.yaml`, so leave those paths holding RKE2 admin kubeconfigs. For the manager use `CLUSTER=rancher-manager HOST=manager.dataknife.net`. If SSH is broken too, see [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md).

## Automation

- The exec plugin works unattended only while the cached token is valid. When it expires (90 days, or after `rancher token delete all`) the next call prints a login link and waits for a human click — scripts and agents hang or fail.
- For unattended jobs use either a **dedicated, scoped Rancher API token** (ideally a separate Rancher user with only the roles it needs; cluster-scoped where possible; rotate before its 90-day cap) or the **RKE2 admin kubeconfigs** (cluster-admin; prefer for infra automation that must survive Rancher outages).
- Never copy a personal kubeconfig token into automation or `terraform.tfvars`.

**Terraform and the Rancher API token**

- What Terraform actually reads is **`config/.rancher-api-token`** (repo root): the `rancher2` provider in `terraform/provider.tf` and the cluster-create / cluster-ID `null_resource`s in `terraform/main.tf`. `deploy-rancher.sh` writes that file on first install.
- `module.rancher_downstream_registration_*` in `terraform/main.tf` passes a **hard-coded** `rancher_token_file = "/home/lee/git/rancher-deploy/config/.rancher-api-token"` (an older checkout path), not the file in this checkout.
- `var.rancher_api_token` (`terraform.tfvars`) is declared but not used by any Terraform resource; only `setup-rancher-kubeconfig.sh` reads it for its one-time lookup.
- On 2026-10-04 the token in both `terraform.tfvars` and `config/.rancher-api-token` was the same expired **kubeconfig** token (HTTP 401). Downstream registration / `register_downstream_cluster` applies need a fresh token first.
- `create-rancher-api-token.sh` and `deploy-rancher.sh` request `ttl: 0`, but `auth-token-max-ttl-minutes` caps it, so the token lasts **90 days**, not forever. Put a rotation reminder on the calendar.

```bash
read -rsp 'Rancher admin (local) password: ' RANCHER_ADMIN_PASSWORD; echo
./scripts/create-rancher-api-token.sh https://rancher.dataknife.net admin "$RANCHER_ADMIN_PASSWORD"
unset RANCHER_ADMIN_PASSWORD
# The script updates rancher_api_token in terraform/terraform.tfvars; Terraform reads config/.rancher-api-token:
sed -nE 's/^[[:space:]]*rancher_api_token[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform/terraform.tfvars > config/.rancher-api-token
chmod 600 config/.rancher-api-token
# Check expiry (token id is the part before ':')
kubectl --context local get tokens.management.cattle.io "$(cut -d: -f1 config/.rancher-api-token)" -o jsonpath='{.expiresAt}{"\n"}'
```

The script logs in through the local provider, so it keeps working with SAML enabled. Also update or symlink the hard-coded path above (or fix it in `main.tf`) before running a registration apply.

## Certificate and expiry calendar

| Item | Expires | Renewal | If missed |
|------|---------|---------|-----------|
| `*.dataknife.net` wildcard (`cert-manager/wildcard-dataknife-net` on manager, Let's Encrypt DNS-01) | 2026-11-15 | cert-manager auto-renews (~2026-10-16). CronJob `cert-manager/cert-sync` (from gitops-core) copies it daily at 02:00 to `kube-system/wildcard-dataknife-net-tls` on downstream clusters, which ingress-nginx uses as default cert (Authentik ingress included) | Browser TLS errors on `*.dataknife.net` apps, including `auth.dataknife.net` |
| `rancher.dataknife.net` (`cattle-system/tls-rancher-ingress`, cert-manager, LE) | 2026-11-15 | Auto-renews (~2026-10-16) | Rancher UI/API TLS errors; CLI login fails |
| Authentik SAML signing cert (`authentik Self-signed Certificate`) | **2027-10-04** | Manual: create a new cert in Authentik, set it on the `Rancher` provider, re-download metadata, paste it into Rancher's SAML config (re-supply the SP key) and re-enable | **All SSO logins fail** |
| Rancher SP cert (`~/.config/rancher-saml/sp.crt`) | 2036-10-01 | Regenerate (above) and re-upload | SSO logins fail |
| RKE2 admin client certs (`system:admin`) used by `cert-sync` | 2027-01-08 | Re-pull `rke2.yaml` after RKE2 rotates certs and refresh the `cert-sync-kubeconfig` Secret (gitops-core) | `cert-sync` stops updating downstream wildcard copies |
| Rancher API / kubeconfig tokens | ≤ 90 days from issue | Re-login (humans) / recreate (automation, `config/.rancher-api-token`) | 401s; exec plugin asks for login |

Spot checks:

```bash
echo | openssl s_client -connect auth.dataknife.net:443 -servername auth.dataknife.net 2>/dev/null | openssl x509 -noout -enddate
kubectl --context local get certificate -A
kubectl --context poc-apps -n kube-system get secret wildcard-dataknife-net-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

As of 2026-10-04 the poc-apps copy had **expired 2026-04-18**: the poc-apps entry in `cert-sync-kubeconfig` uses a Rancher-proxy URL with a deleted kubeconfig token, and the job's `alpine/k8s:1.29.4` image fails x509 verification against `rancher.dataknife.net` (likely an outdated CA bundle for the newer Let's Encrypt chain). nprd/prd/manager entries use RKE2 client certs and are current. Fix in gitops-core (switch poc-apps to an RKE2 admin kubeconfig entry).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `inappropriate ioctl for device` | A `-local` context prompted for a password with no TTY (agent, script, IDE task) | Run it in a real terminal, or use the SSO context |
| Username prompt shows `user-f4528` as default | `--user` is the Rancher user ID | Type `admin` |
| Link printed but nothing happens | Pop-up blocked, or link not opened | Allow pop-ups for `rancher.dataknife.net`; open the link manually; the CLI keeps polling |
| 401 / `Unauthorized` / repeated login prompts | Cached token expired or revoked | `rancher token delete all`, then retry |
| `rancher: executable file not found` | CLI missing or not on `PATH` | Re-run the script with `--install-cli`; add `~/.local/bin` to `PATH` |
| CLI asks which auth provider to use | Context written without `--auth-provider` | Re-run the setup script with `--auth-provider keyCloakProvider --break-glass` |
| `no working Rancher API token found` (setup script) | No token source for the one-time lookup | `export RANCHER_TOKEN=...` (short-lived UI key) and re-run |
| Names resolve to old IPs after DNS changes | Stale local resolver cache | `resolvectl flush-caches` |
| SSO login rejected for a valid Authentik user | Site access is `required`/`restricted` and the user isn't allowed | Add the user/group in **Site Access**, or switch to `unrestricted` |
| Can't find a user/group when granting roles | SAML has no search; principal unknown until first login | Have them log in once, then assign |
| SAML save fails / provider disabled after editing | SP private key not re-supplied | **Read from a file** → `sp.key`, save, re-enable in a browser |
| SAML errors after an Authentik cert change | Rancher still has old IdP metadata | Re-download metadata into Rancher's SAML config |
| Authentik login page down | prd-apps / ingress / Authentik pods unhealthy | Local login or `-local` contexts; `kubectl --context prd-apps-local -n authentik get pods`; `logs deploy/authentik-server` |

## Related

- [SSH_AND_ACCESS.md](SSH_AND_ACCESS.md) — deploy keys, SSH recovery via `kubectl debug`
- [RANCHER_API_TOKEN_CREATION.md](RANCHER_API_TOKEN_CREATION.md) — Terraform automation token
- [RANCHER_DOWNSTREAM_MANAGEMENT.md](RANCHER_DOWNSTREAM_MANAGEMENT.md) — downstream registration
- [OPS_NOTES.md](OPS_NOTES.md) — short operational truths and known issues
- [../scripts/setup-rancher-kubeconfig.sh](../scripts/setup-rancher-kubeconfig.sh) — header documents all flags
