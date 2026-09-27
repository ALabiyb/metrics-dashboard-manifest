<!-- ---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
--------------------------------------------------------------------------- -->
# metrics-dashboard Helm chart

Packages InfraWatch (the metrics-dashboard app) for reuse on other clusters,
replacing the raw manifests in `../k8s/`. `values.yaml` holds generic,
OSS-ready defaults; `values-dev.yaml` / `values-uat.yaml` / `values-prod.yaml`
hold only the deltas for the softnet.co.tz cluster's three environments and
are meant to be layered on top.

## Preview a render

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
`spec.destination.namespace` below, exactly like the raw manifests today.

Secrets (`DASHBOARD_USERS`, `SESSION_SECRET`, `EMBED_TOKEN`,
`OIDC_CLIENT_SECRET`, `SMTP_USERNAME`/`SMTP_PASSWORD`) default to being
created from `secret.*` values for convenience, but those land in
`helm get values`/release history in plaintext. For anything beyond a quick
local install, set `secret.create: false` and `secret.existingSecretName` to
a Secret created out-of-band instead — see `../k8s-metrics/secret.example.yaml`
in the metrics-dashboard app repo for the exact `kubectl create secret`
incantation; this is how dev/uat/prod actually provision it today (generated
imperatively, not tracked by GitOps, so it survives ArgoCD `selfHeal`).

## Switching a live ArgoCD env from raw manifests to this chart

The live `argocd/metrics-dashboard-{dev,uat,prod}.yaml` Applications are
**not modified by this chart** — they still point `path: k8s` at the raw
manifests. To cut an environment over, change that Application's `source` to:

```yaml
source:
  repoURL: http://192.168.15.85/kubernetes-manifest/metrics-dashboard.git
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
See `argocd/metrics-dashboard-dev.yaml.helm-example` for a ready-to-diff
example of what the switched-over Application would look like (not applied
anywhere — copy it over the real file only once you're ready to cut over).

## Known gaps / judgment calls

- `values-uat.yaml`'s `image.tag` is left as `CHANGE_ME_tag` because the live
  `uat` branch's `k8s/02-deployment.yaml` still carries that same placeholder
  — uat's build pipeline hasn't pinned a real tag as of this chart's
  creation. Fill in the real tag before using this file for an actual deploy.
- `values-prod.yaml` assumes prod is still isolated by namespace on the same
  cluster as dev/uat (matches the current live state) — the live
  `argocd/metrics-dashboard-prod.yaml`'s separate-cluster destination block
  is a commented-out placeholder (`CHANGE_ME_PROD_CLUSTER_API_IP`), not yet
  wired up. Once a real separate prod cluster exists, its Application's
  `destination.server` changes; this chart's values do not need to.
- `httpRoute` (Gateway API) is enabled by default to match current behavior,
  but is fully optional (`httpRoute.enabled: false`) for clusters without the
  Gateway API CRDs installed.
