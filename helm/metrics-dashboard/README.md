<!-- ---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
--------------------------------------------------------------------------- -->
# metrics-dashboard Helm chart

Packages **InfraWatch** — a live operations dashboard that watches your
Kubernetes cluster nodes and any external (non-Kubernetes) servers side by
side, with email alerting and optional Keycloak SSO. This chart replaces the
raw manifests in `../k8s/` so the same app can be installed on any cluster,
not just the one it was originally built for.

If you've never used Helm before, read "New to Helm?" below first. If you
just need the install command, skip to
[Installing for real](#installing-for-real-a-genuinely-new-clustercustomer).

---

## New to Helm?

A **Helm chart** is a template for a set of Kubernetes objects (a
Deployment, a Service, a ConfigMap, etc.). Instead of hand-editing raw YAML
files for every environment, you fill in one `values.yaml` file with your
settings — your company name, your image tag, your alert email addresses —
and Helm generates the final Kubernetes YAML for you.

- `values.yaml` — the chart's own generic defaults. You override pieces of
  it, you don't edit it directly.
- `values-dev.yaml`, `values-uat.yaml`, `values-prod.yaml` — this repo's
  real settings for SoftNet's three environments. These get **layered on
  top of** `values.yaml` (later files win on any key they both set).
- `templates/` — the actual Kubernetes YAML, with `{{ .Values.something }}`
  placeholders that get filled in from whichever values files you pass.
- `helm template` — renders the final YAML to your screen without touching
  any cluster. Always safe to run.
- `helm install` — renders the YAML *and* applies it to whatever cluster
  your `kubectl` is currently pointed at. This changes real infrastructure.

---

## Architecture — what this app actually does

```
                    ┌─────────────────────┐
   node-exporter  →  │                     │
   (cluster nodes)   │                     │
                      │     Prometheus      │ ← scrapes metrics every ~15s
   node-exporter  →  │  (already running,  │
   process-exporter   │   NOT part of this  │
   (external-vms job) │   chart)             │
                      └──────────┬──────────┘
                                 │ PromQL queries, polled every few seconds
                                 ▼
                      ┌─────────────────────┐        ┌──────────────┐
   browser  ────────→ │  metrics-dashboard  │ ──────→ │  Alertmanager │
   (login page,       │   (THIS chart)      │  polls  │ (not part of │
    Overview, Nodes,  │                     │         │  this chart) │
    Alerts pages)      └──────────┬──────────┘        └──────────────┘
                                  │ on a firing alert
                                  ▼
                      ┌─────────────────────┐
                      │   SMTP (Zoho, etc.)  │ → NOC email, routed by
                      │                       │   node-group (see
                      └─────────────────────┘   "Alert routing" below)

   Keycloak (optional) ──OIDC login──→ metrics-dashboard
```

**What it shows**: for every cluster node and every external server, live
CPU/memory/disk/network gauges, the top processes by CPU, and — for disks —
a per-mountpoint breakdown (not a blended average across every disk on the
box, since that can hide a single nearly-full disk behind a healthy-looking
number). It also shows Ceph health, Pods, and ArgoCD sync status when those
are available in Prometheus.

**Who can see what**: three levels, set via Keycloak group membership (see
`oidc.adminGroup` / `oidc.scopedViewerGroups` below), or hardcoded local
accounts if you don't use Keycloak at all:
- **admin** — everything, plus the Settings page (server status, "send test
  email").
- **scoped viewer** — only external servers whose name starts with a
  configured prefix (e.g. a team in `vfd-group` only ever sees `vfd-*`
  servers, nothing else in the dashboard). Optional — off unless you
  configure it.
- **viewer** — everything else, read-only, no scoping.

**What's currently live on SoftNet's dev cluster** (namespace
`metrics-dashboard-dev`), as a concrete example of what these values mean
in practice:
- `APP_COMPANY_NAME=InfraWatch`, `APP_CLUSTER_NAME=dev-cluster`
- Admin access: Keycloak groups `k8s-cluster-admins` and
  `k8s-platform-admins` (comma-separated — see `oidc.adminGroup` below)
- Scoped viewer: Keycloak group `vfd-group` → sees only `vfd-*` servers
- NOC alerting is on: `admin@nexbridge.co.tz` is CC'd on every alert; cluster
  node alerts additionally go to `oncall-infra@nexbridge.co.tz` and
  `oncall-infra@nexbridge.co.tz`; vfd-server alerts additionally go to
  `oncall-vfd@nexbridge.co.tz`

---

## What's in this chart

| File | Kubernetes object | What it's for |
|---|---|---|
| `templates/configmap.yaml` | ConfigMap | Non-secret settings — company name, Prometheus/Alertmanager URLs, alert routing addresses, OIDC config |
| `templates/deployment.yaml` | Deployment | The app itself (2 replicas by default) |
| `templates/service.yaml` | Service | Exposes the app's HTTP port (and the `/tv` kiosk port) inside the cluster |
| `templates/httproute.yaml` | HTTPRoute (Gateway API) | Optional public hostname routing — turn off with `httpRoute.enabled: false` if your cluster doesn't have Gateway API |
| `templates/secret.yaml` | Secret | Login credentials, session/embed tokens, SMTP password, OIDC client secret |

## What's *not* in this chart (on purpose)

This chart only packages the dashboard app itself. It assumes Prometheus,
Alertmanager, and (optionally) Keycloak already exist on your cluster —
it doesn't install or manage them.

One more thing worth knowing: **`process-exporter` (the DaemonSet that
feeds the per-node "Top Processes" table and per-mountpoint disk data) is
*not* part of this chart either.** It lives as a plain, hand-applied
manifest at `../k8s-metrics/process-exporter.yaml` in this repo, with no
ArgoCD Application watching it — someone has to `kubectl apply` it by hand
when it changes. The dashboard still works without it; you'll just see no
"Top Processes" section for hosts it isn't running on (this is exactly
what happens today for a couple of the real external servers). Bringing
it under this chart, or under GitOps at all, is a reasonable follow-up if
you want one less manual step.

---

## Before you install: decisions to make

1. **Do you have Keycloak?** If yes, fill in `oidc.*` below. If no, leave
   `oidc.issuerUrl` blank — the app falls back to local username/password
   accounts (`secret.dashboardUsers`) and simply hides the SSO button.
2. **Do you want NOC email alerts?** They're **off by default**. To turn
   them on you need both `secret.smtpUsername` and `secret.smtpPassword`
   set — leaving either blank keeps alerting fully disabled, regardless of
   what else you configure under `alerting:`.
3. **Does your cluster have Gateway API installed** (`gateway.networking.k8s.io`
   CRDs)? If not, set `httpRoute.enabled: false` — the Service still works
   fine on its own via `kubectl port-forward` or your own Ingress.
4. **Are you replacing a live install, or doing a fresh one?** See the two
   different sections below — they need different secret handling.

---

## Preview a render

Safe to run any time — never touches a cluster:

```sh
helm lint .
helm template . -f values.yaml -f values-dev.yaml
helm template . -f values.yaml -f values-uat.yaml
helm template . -f values.yaml -f values-prod.yaml
```

## Installing for real (a genuinely new cluster/customer)

```sh
helm install metrics-dashboard . \
  -n metrics-dashboard --create-namespace \
  -f values.yaml \
  --set image.repository=your.registry/your-project/metrics-dashboard \
  --set image.tag=1.0.0 \
  --set branding.companyName="Your Company" \
  --set branding.clusterName="your-cluster" \
  --set alerting.emailTo='{noc@your-company.com}'
```

Namespace is deliberately never hardcoded in this chart's templates — it
comes from `-n <namespace>` here, or from the ArgoCD Application's
`spec.destination.namespace` (see below), exactly like the raw manifests
today.

**Secrets on a fresh install**: leaving everything under `secret:` blank is
fine to start — `SESSION_SECRET` and `EMBED_TOKEN` auto-generate themselves
on first install and stay stable across upgrades (so `helm upgrade` never
silently logs everyone out). The one thing that genuinely can't be
auto-generated is `secret.dashboardUsers` — it needs real usernames and
bcrypt password hashes, so the pod will crash-loop until you set it. The
chart tells you this loudly in its post-install `NOTES.txt` if you forget.
Generate a hash with:

```sh
go run . hash-password '<plaintext password>'
```

(run from the `metrics-dashboard` app source repo), then:

```sh
--set-json 'secret.dashboardUsers=[{"username":"admin","password_hash":"$2a$...","role":"admin"}]'
```

## Replacing a live install (what dev/uat/prod actually do)

The real dashboard-auth Secret on SoftNet's clusters is created **out of
band** (an imperative `kubectl create secret`, not tracked in this repo),
specifically so it survives ArgoCD's `selfHeal` without this chart ever
seeing the real values. That's why every `values-<env>.yaml` here sets:

```yaml
secret:
  create: false
  existingSecretName: "dashboard-auth"
```

If you're cutting an *existing* live environment over to this chart, do
the same — point `existingSecretName` at whatever Secret is already there
rather than letting the chart create a new one, or Helm will fight the
real Secret with blank/placeholder values.

## Switching a live ArgoCD env from raw manifests to this chart

The live `argocd/metrics-dashboard-{dev,uat,prod}.yaml` Applications are
**not modified by this chart** — they still point `path: k8s` at the raw
manifests. To cut an environment over, change that Application's `source` to:

```yaml
source:
  repoURL: https://github.com/ALabiyb/metrics-dashboard-manifest.git
  targetRevision: dev            # or uat / prod
  path: helm/metrics-dashboard
  helm:
    valueFiles:
      - values.yaml
      - values-dev.yaml         # or values-uat.yaml / values-prod.yaml
```

Resource names (`metrics-dashboard` Deployment, `metrics-dashboard-config`
ConfigMap, `dashboard` Service, `dashboard-auth` Secret) are pinned to match
the existing live objects exactly, so this is a same-name, non-disruptive
replacement — ArgoCD adopts the existing objects instead of recreating them.
See `../argocd/metrics-dashboard-dev.yaml.helm-example` for a ready-to-diff
example of what the switched-over Application would look like (not applied
anywhere — copy it over the real file only once you're ready to cut over).

---

## Full values reference

### Identity / naming

| Key | Default | What it does |
|---|---|---|
| `nameOverride` | `""` | Base name for auto-generated resource names. Every `values-<env>.yaml` here sets this to `"metrics-dashboard"` so it matches the live objects exactly — don't change it for an existing environment. |
| `podLabel` | `"dashboard"` | The `app:` selector label every resource uses. Must match the raw manifests' label if you're replacing a live install. |
| `replicaCount` | `2` | How many dashboard pods to run. |

### Image

| Key | Default | What it does |
|---|---|---|
| `image.repository` | placeholder | Your container registry path. **Must be set** — the placeholder won't pull. |
| `image.tag` | placeholder | Image version. **Must be set.** |
| `image.pullPolicy` | `Always` | Standard Kubernetes field. |

### Networking

| Key | Default | What it does |
|---|---|---|
| `service.type` | `NodePort` | How the Service is exposed. |
| `service.tv.enabled` | `true` | Exposes the unauthenticated `/tv` kiosk-mode route on its own port — for a TV wall display, not for regular login. Set `false` if you don't need it. |
| `httpRoute.enabled` | `true` | Gateway API public routing. **Turn off if your cluster doesn't have Gateway API CRDs installed** — everything else still works. |
| `httpRoute.parentRef.*` | example values | Which Gateway this HTTPRoute attaches to. |
| `httpRoute.hostnames` | example.com | The public hostname(s) users will visit. |

### Branding & data source

| Key | Default | What it does |
|---|---|---|
| `app.env` | `"production"` | Controls a small "Development" badge on the login page — set to anything else to show it. |
| `branding.companyName` | `"InfraWatch"` | Shown throughout the UI (login page, sidebar, TV bar). |
| `branding.clusterName` | `"cluster"` | Shown next to the company name, so you can tell clusters apart if you run more than one. |
| `dataSource.prometheusUrl` | example | **Must point at a real Prometheus** for the dashboard to show real data instead of simulated demo data. |
| `dataSource.alertmanagerUrl` | example | Where the app polls for firing alerts (both the in-app Alerts page and NOC email depend on this). |
| `links.dashboardUrl` / `k8sDashboardUrl` / `argocdUrl` | `""` | Cross-links shown in the nav. Leave blank to hide a link entirely. |

### Keycloak SSO (optional)

| Key | Default | What it does |
|---|---|---|
| `oidc.issuerUrl` | `""` | **Leave blank to disable SSO entirely** — the app falls back to local accounts only. |
| `oidc.clientId` | `"metrics-dashboard"` | The Keycloak client ID you register for this app. |
| `oidc.redirectUrl` | `""` | Must exactly match what's registered as a valid redirect URI in Keycloak. |
| `oidc.adminGroup` | `"k8s-cluster-admins"` | Comma-separated list of Keycloak groups that grant admin. A user in *any* listed group is admin — this is why you can list both a "platform admin" and a "cluster admin" group without one needing to imply the other. |
| `oidc.scopedViewerGroups` | `""` | Comma-separated `group:prefix` pairs (e.g. `vfd-group:vfd-,billing-team:billing-`). A user in a listed group only sees external servers whose name starts with that prefix — everything else in the dashboard (cluster nodes, Ceph, Pods, ArgoCD) is hidden for them, not shown empty. Add a new team any time by adding one more `group:prefix` entry — no code change, no redeploy. |
| `oidc.tlsSkipVerify` | `"true"` | Set `"false"` once your Keycloak has a certificate from a CA your cluster already trusts. |

### NOC email alerting (optional)

Fully **off** by default — requires both `secret.smtpUsername` and
`secret.smtpPassword` to be set before any email ever sends, regardless of
what's configured here.

| Key | Default | What it does |
|---|---|---|
| `alerting.emailTo` | `[]` | Always CC'd on every alert email that's in scope (see below), and the sole recipient if no more specific route matches. |
| `alerting.smtp.host` / `.port` | `smtp.zoho.com` / `587` | Your SMTP server. |
| `alerting.smtp.fromName` | `""` | Falls back to `"<companyName> Metrics"` if left blank. |
| `alerting.smtp.from` | `""` | Falls back to `secret.smtpUsername` if left blank. |
| `alerting.routes.clusterNodes` | `[]` | Extra recipients for alerts about a Kubernetes cluster node. |
| `alerting.routes.vfd` | `[]` | Extra recipients for alerts about a `vfd-*`-named external server. |
| `alerting.routes.gitlabDevops` | `[]` | Extra recipients for alerts about the GitLab/DevOps hosts specifically. |

Only alerts that are actually about **your** infrastructure (cluster nodes
or the `external-vms` job) ever get emailed — not every alert firing on a
shared cluster (pod crash loops, ArgoCD sync failures, etc. stay in the
in-app Alerts page only).

### Secrets

| Key | Default | What it does |
|---|---|---|
| `secret.create` | `true` | `false` to use an existing, externally-managed Secret instead (recommended for anything beyond a quick local install — see above). |
| `secret.existingSecretName` | `""` | Required when `secret.create: false`. |
| `secret.dashboardUsers` | `""` | JSON array of `{"username","password_hash","role"}`. **No safe default exists** — must be set or the pod crash-loops. |
| `secret.sessionSecret` / `secret.embedToken` | `""` | Pure random tokens. Leave blank — they auto-generate on first install and stay stable across upgrades. |
| `secret.oidcClientSecret` | `""` | Required if `oidc.issuerUrl` is set. |
| `secret.smtpUsername` / `secret.smtpPassword` | `""` | Required (both) to turn on NOC email alerting. |

### Resources

| Key | Default |
|---|---|
| `resources.requests.cpu` / `.memory` | `50m` / `64Mi` |
| `resources.limits.cpu` / `.memory` | `250m` / `128Mi` |

---

## Troubleshooting a first install

- **Pod stuck in `CrashLoopBackOff`, logs mention `DASHBOARD_USERS`**: you
  left `secret.dashboardUsers` blank. See [Secrets](#secrets) above.
- **Login page loads but SSO button is missing**: `oidc.issuerUrl` is
  blank — that's the switch, not a bug. Set it (and the other four
  `oidc.*`/`secret.oidcClientSecret` values) to enable it.
- **Test email button in Settings does nothing / errors**: `secret.smtpUsername`
  or `secret.smtpPassword` is blank. Both are required, not just one.
- **Dashboard loads but every gauge shows 0 / "simulated" data**: check
  `dataSource.prometheusUrl` — it's either wrong or Prometheus isn't
  reachable from inside the cluster.
- **`helm install` succeeds but nothing is reachable from outside the
  cluster**: either your Gateway API setup doesn't match `httpRoute.*`, or
  your cluster doesn't have Gateway API at all — set `httpRoute.enabled:
  false` and use `kubectl port-forward svc/dashboard 8090:80` to confirm
  the app itself is healthy first.

## Known gaps / judgment calls

- `values-uat.yaml`'s `image.tag` is left as `CHANGE_ME_tag` because the live
  `uat` branch's `k8s/02-deployment.yaml` still carries that same placeholder
  — uat's build pipeline hasn't pinned a real tag as of this writing. Fill
  in the real tag before using this file for an actual deploy.
- `values-prod.yaml` assumes prod is still isolated by namespace on the same
  cluster as dev/uat (matches the current live state) — the live
  `argocd/metrics-dashboard-prod.yaml`'s separate-cluster destination block
  is a commented-out placeholder (`CHANGE_ME_PROD_CLUSTER_API_IP`), not yet
  wired up. Once a real separate prod cluster exists, its Application's
  `destination.server` changes; this chart's values do not need to.
- `httpRoute` (Gateway API) is enabled by default to match current behavior,
  but is fully optional (`httpRoute.enabled: false`) for clusters without the
  Gateway API CRDs installed.
- `process-exporter` (see "What's not in this chart" above) still isn't
  under GitOps at all — a real gap worth closing at some point, not
  something this chart currently solves.
