# Deployment Guide — metrics-dashboard

A step-by-step guide for deploying the metrics-dashboard to a Kubernetes cluster using **GitOps with ArgoCD**. Covers everything from cluster bootstrap to per-environment rollout, troubleshooting, and the TV wall integration.

This guide is also valid for **k8s-dashboard** — the steps are identical, only some names and namespaces differ. See [§ Adapting for k8s-dashboard](#adapting-for-k8s-dashboard) at the end.

---

## Table of contents

- [Overview](#overview)
- [How the pieces fit together](#how-the-pieces-fit-together)
- [Repository layout](#repository-layout)
- [Branch strategy](#branch-strategy)
- [Prerequisites](#prerequisites)
- [One-time cluster bootstrap](#one-time-cluster-bootstrap)
  - [1. Trust the Harbor TLS certificate on every node](#1-trust-the-harbor-tls-certificate-on-every-node)
  - [2. Verify ArgoCD is installed](#2-verify-argocd-is-installed)
  - [3. Add GitLab credentials to ArgoCD](#3-add-gitlab-credentials-to-argocd)
- [Per-environment deployment](#per-environment-deployment)
  - [Step 1 — Create the target namespace](#step-1--create-the-target-namespace)
  - [Step 2 — Create the dashboard-auth Secret](#step-2--create-the-dashboard-auth-secret)
  - [Step 3 — Apply the ArgoCD Application](#step-3--apply-the-argocd-application)
  - [Step 4 — Verify the sync](#step-4--verify-the-sync)
  - [Step 5 — Configure DNS](#step-5--configure-dns)
  - [Step 6 — Update Keycloak client (if using SSO)](#step-6--update-keycloak-client-if-using-sso)
  - [Step 7 — Verify access](#step-7--verify-access)
- [TV Wall integration](#tv-wall-integration)
- [Daily operations](#daily-operations)
- [Troubleshooting](#troubleshooting)
- [Adapting for k8s-dashboard](#adapting-for-k8s-dashboard)

---

## Overview

The metrics-dashboard is a Go-based NOC dashboard showing live Kubernetes node CPU, memory, disk, network metrics + Ceph health, pulled from Prometheus. It runs as a Deployment in a Kubernetes cluster, with two consumers:

1. **Browser users** — sign in via username/password or Keycloak SSO, see the dashboard at `https://metrics-dashboard.<env>.softnethq.co.tz`
2. **TV kiosk** — uses a static `EMBED_TOKEN` to auto-login as a viewer, displayed on a Samsung TV

Each environment (`dev`, `uat`, `prod`) runs on its own Kubernetes cluster (or namespace). Deployments are fully **GitOps-managed by ArgoCD** — Jenkins updates the manifest repo, ArgoCD detects the change and applies it.

---

## How the pieces fit together

```
┌──────────────┐   git push    ┌────────────────────────┐
│  Developer   │ ────────────► │  GitLab — source repo  │
└──────────────┘               │  devsecops1/           │
                               │   metrics-dashboard.git│
                               └───────────┬────────────┘
                                           │ webhook
                                           ▼
                               ┌────────────────────────┐
                               │       Jenkins          │
                               │  ┌──────────────────┐  │
                               │  │ Build + scan +   │  │
                               │  │ push image +     │  │
                               │  │ update manifest  │  │
                               │  └──────────────────┘  │
                               └────┬──────────────┬────┘
                                    │              │
                            push    │              │ git commit
                            image   ▼              ▼
                       ┌──────────────┐   ┌──────────────────────┐
                       │   Harbor     │   │  GitLab — manifest   │
                       │  registry    │   │  kubernetes-manifest/│
                       └──────┬───────┘   │   metrics-dashboard  │
                              │           │  branches:           │
                              │           │   dev | uat | prod   │
                              │           └──────────┬───────────┘
                              │                      │ polls / webhook
                              │                      ▼
                              │           ┌──────────────────────┐
                              │           │       ArgoCD         │
                              │           │  (per-cluster)       │
                              │           └──────────┬───────────┘
                              │                      │ kubectl apply
                              ▼                      ▼
                       ┌──────────────────────────────────┐
                       │   Kubernetes cluster (dev/prod)  │
                       │   ┌─────────────────────────┐    │
                       │   │ metrics-dashboard pods  │    │
                       │   └────────────┬────────────┘    │
                       │                ▼                 │
                       │   ┌─────────────────────────┐    │
                       │   │  Prometheus (in-cluster)│    │
                       │   └─────────────────────────┘    │
                       └──────────────────────────────────┘
```

**Key design principles:**

- **One manifest repo, multiple branches.** `dev`, `uat`, `prod` branches each describe the desired state for one environment. The only differences between branches are: image tag (set by Jenkins), `APP_ENV`, `CLUSTER_NAME`, hostname.
- **Image tag is the only thing Jenkins writes.** All other config (ports, resources, env vars) is set by you in the manifest repo and never touched by CI.
- **Secrets never live in git.** The `dashboard-auth` Secret is created out-of-band on each cluster.
- **Each cluster has its own ArgoCD instance.** Dev ArgoCD manages dev cluster; prod ArgoCD manages prod cluster. Simpler than multi-cluster ArgoCD and avoids cross-cluster credential management.

---

## Repository layout

```
metrics-dashboard-manifest/
├── README.md
├── DEPLOYMENT.md                     ← this file
├── k8s.example.secret.yaml           ← reference only, do NOT apply
├── k8s/                              ← what ArgoCD syncs
│   ├── 01-configmap.yaml             ← env vars (per-branch values)
│   ├── 02-deployment.yaml            ← pod spec, image tag (set by Jenkins)
│   ├── 03-service.yaml               ← ClusterIP + NodePort for TV
│   └── 04-httproute.yaml             ← Istio Gateway route + hostname
└── argocd/                           ← ArgoCD Application definitions
    ├── metrics-dashboard-dev.yaml
    ├── metrics-dashboard-uat.yaml
    └── metrics-dashboard-prod.yaml
```

**Important:** `k8s.example.secret.yaml` is intentionally **outside** the `k8s/` folder so ArgoCD doesn't pick it up. If it lived inside `k8s/`, ArgoCD would sync it and overwrite the real secret with placeholders on every reconcile.

---

## Branch strategy

| Branch | Image tag | `APP_ENV` (configmap) | Hostname | NodePort | Cluster |
|---|---|---|---|---|---|
| `main` | latest | `Development` | `metrics-dashboard.dev.softnethq.co.tz` | `32029` | (template) |
| `dev` | `:build-number` (e.g. `:42`) | `Development` | `metrics-dashboard.dev.softnethq.co.tz` | `32030` | dev |
| `uat` | `:build-number` | `Development` (or `UAT`) | `metrics-dashboard.uat.softnethq.co.tz` | (TBD) | dev (separate namespace) |
| `prod` | `:RELEASE_VERSION` (e.g. `:1.0.0`) | `Production` | `metrics-dashboard.prod.softnethq.co.tz` | `32029` | prod |

**Why `dev` uses NodePort 32030 instead of 32029:** NodePorts are cluster-wide unique. There's an older manually-deployed metrics-dashboard on the dev cluster using 32029, so the new ArgoCD-managed dev one runs on 32030 to avoid conflict. On the prod cluster (fresh) we can use 32029.

---

## Prerequisites

Before deploying to a new cluster, you need:

| Component | Why needed |
|---|---|
| **Kubernetes cluster (1.27+)** | Runtime |
| **containerd** with Harbor cert trust | To pull `harbor.devops.softnethq.co.tz` images |
| **ArgoCD** installed in `argocd` namespace | GitOps engine |
| **Gateway API** + **Istio** | For HTTPS access (HTTPRoute → main-gateway) |
| **cert-manager** + a wildcard TLS cert | Terminates TLS at the gateway |
| **Prometheus** running in `monitoring` namespace | Dashboard reads from it |
| **GitLab** at `http://192.168.15.85` reachable | ArgoCD pulls manifests from here |
| **Harbor** at `harbor.devops.softnethq.co.tz` reachable | Cluster pulls images from here |
| **Keycloak** (optional) | For SSO login |
| **DNS** for `*.<env>.softnethq.co.tz` | Resolves to the cluster's Istio gateway IP |

---

## One-time cluster bootstrap

These steps run **once per Kubernetes cluster**. Once done, every dashboard deployment to that cluster uses the same infrastructure.

### 1. Trust the Harbor TLS certificate on every node

Harbor uses an internal CA. Without trust, every pod pull fails with:
```
x509: certificate signed by unknown authority
```

**This must be done on every node** (master + all workers). The pod could be scheduled on any of them.

```bash
# Extract Harbor's CA cert (from any machine with network access to Harbor)
openssl s_client -connect harbor.devops.softnethq.co.tz:443 -showcerts </dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  > /tmp/harbor-ca.crt

# On EACH node:
sudo mkdir -p /etc/containerd/certs.d/harbor.devops.softnethq.co.tz
sudo cp /tmp/harbor-ca.crt /etc/containerd/certs.d/harbor.devops.softnethq.co.tz/ca.crt

sudo tee /etc/containerd/certs.d/harbor.devops.softnethq.co.tz/hosts.toml > /dev/null <<'EOF'
server = "https://harbor.devops.softnethq.co.tz"

[host."https://harbor.devops.softnethq.co.tz"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/harbor.devops.softnethq.co.tz/ca.crt"
EOF

# Make sure containerd actually reads the certs.d directory.
# Edit /etc/containerd/config.toml and find this section:
#   [plugins."io.containerd.grpc.v1.cri".registry]
#     config_path = ""           ← must NOT be empty
# Change it to:
#     config_path = "/etc/containerd/certs.d"
#
# (Note: there are sometimes TWO config_path entries in the file —
#  the empty one under [plugins."io.containerd.grpc.v1.cri".registry] is
#  the one that matters for image pulls.)

sudo systemctl restart containerd

# Verify
sudo crictl pull harbor.devops.softnethq.co.tz/k8s_dashboard/metrics-dashboard:1.0.0
# Expected: image pulled or "Image is up to date" — NOT a TLS error
```

To do this across many nodes quickly, see [the Containerd cert distribution script](#troubleshooting) at the bottom.

### 2. Verify ArgoCD is installed

```bash
kubectl get pods -n argocd
```

You should see `argocd-server`, `argocd-repo-server`, `argocd-application-controller` Running.

If you don't have ArgoCD yet, install it:
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### 3. Add GitLab credentials to ArgoCD

ArgoCD needs to clone the manifest repo from GitLab. Since the repo requires authentication, add a credentials template — it applies to **any** repo URL starting with the same host, so one entry covers metrics-dashboard, k8s-dashboard, and any future manifest repos.

```bash
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://192.168.15.85
  username: lsaid
  password: <YOUR_GITLAB_PERSONAL_ACCESS_TOKEN>
EOF

# Restart the repo-server so it picks up the new credentials immediately
kubectl -n argocd rollout restart deployment argocd-repo-server
```

**Get a Personal Access Token from GitLab:**
1. GitLab → top right avatar → Edit profile → Access tokens
2. Name: `argocd-readonly`, scopes: `read_repository` (read-only is enough)
3. Create → copy the value (only shown once)

---

## Per-environment deployment

For each environment (dev or prod), follow these steps **on the target cluster**.

### Step 1 — Create the target namespace

```bash
# Dev
kubectl create namespace metrics-dashboard-dev

# Prod
kubectl create namespace metrics-dashboard-prod
```

> Note: ArgoCD's `CreateNamespace=true` option would create it for you, but creating it manually lets you also pre-create the Secret in the same step.

### Step 2 — Create the dashboard-auth Secret

This Secret holds the credentials the pod reads at startup. It is **never** in git — see [§ Why these secrets matter](../README.md#why-these-secrets-matter-plain-language-explainer) in the source README for what each value does.

```bash
# Generate fresh random values (PROD MUST have different values from DEV)
SESSION_SECRET=$(openssl rand -base64 32)
EMBED_TOKEN=$(openssl rand -hex 32)

# Hash a strong admin password using the dashboard binary itself
HASH_ADMIN=$(kubectl run hash --rm -i --restart=Never \
  --image=harbor.devops.softnethq.co.tz/k8s_dashboard/metrics-dashboard:1.0.0 \
  --command -- /app/dashboard hash-password 'YourStrongAdminPassword' 2>/dev/null | tail -1)

HASH_VIEWER=$(kubectl run hashv --rm -i --restart=Never \
  --image=harbor.devops.softnethq.co.tz/k8s_dashboard/metrics-dashboard:1.0.0 \
  --command -- /app/dashboard hash-password 'YourStrongViewerPassword' 2>/dev/null | tail -1)

# Get the Keycloak client secret (only if SSO is enabled)
# Keycloak Admin → realm 'k8s dashboard' → Clients → metrics-dashboard → Credentials tab
KEYCLOAK_CLIENT_SECRET='<paste-from-keycloak>'

# Create the Secret in the target namespace
NAMESPACE=metrics-dashboard-prod   # or metrics-dashboard-dev

kubectl create secret generic dashboard-auth -n $NAMESPACE \
  --from-literal=DASHBOARD_USERS="[{\"username\":\"admin\",\"password_hash\":\"${HASH_ADMIN}\",\"role\":\"admin\"},{\"username\":\"viewer\",\"password_hash\":\"${HASH_VIEWER}\",\"role\":\"viewer\"}]" \
  --from-literal=SESSION_SECRET="$SESSION_SECRET" \
  --from-literal=EMBED_TOKEN="$EMBED_TOKEN" \
  --from-literal=OIDC_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET"

# Save the EMBED_TOKEN — you need it later for the TV iframe URL
echo "==============================================="
echo "EMBED_TOKEN (save for TV nginx iframe URL):"
echo "$EMBED_TOKEN"
echo "==============================================="
```

### Step 3 — Apply the ArgoCD Application

```bash
# Clone the manifest repo (or download just the argocd file)
git clone http://192.168.15.85/kubernetes-manifest/metrics-dashboard.git /tmp/md-manifest

# Apply the right ArgoCD app for this environment
kubectl apply -n argocd -f /tmp/md-manifest/argocd/metrics-dashboard-prod.yaml
# OR for dev:
# kubectl apply -n argocd -f /tmp/md-manifest/argocd/metrics-dashboard-dev.yaml

# Cleanup
rm -rf /tmp/md-manifest
```

### Step 4 — Verify the sync

```bash
# Watch ArgoCD pull the manifest, create resources, and start pods
kubectl -n argocd get application metrics-dashboard-prod -w

# Eventually you want to see:
#   STATUS: Synced
#   HEALTH: Healthy

# Verify the pods are running
kubectl -n metrics-dashboard-prod get pods,svc

# Check logs for startup
kubectl -n metrics-dashboard-prod logs -l app=dashboard --tail=30
```

**Expected pod logs:**
```
"data source: real cluster via Prometheus (http://prometheus-stack-...)"
"oidc: Keycloak SSO enabled (issuer ...)"
"K8s + Ceph dashboard listening on http://localhost:8090"
```

### Step 5 — Configure DNS

Add an A record for the environment hostname pointing at the cluster's Istio gateway external IP:

```
metrics-dashboard.prod.softnethq.co.tz  →  <prod cluster Istio gateway IP>
metrics-dashboard.dev.softnethq.co.tz   →  <dev cluster Istio gateway IP>
```

Get the gateway IP:
```bash
kubectl -n istio-system get svc istio-ingressgateway
```

### Step 6 — Update Keycloak client (if using SSO)

The same `metrics-dashboard` Keycloak client serves all environments — just add the new redirect URI:

1. Keycloak Admin → realm `k8s dashboard` → Clients → `metrics-dashboard` → Settings tab
2. **Valid Redirect URIs**: add `https://metrics-dashboard.<env>.softnethq.co.tz/login/oidc/callback`
3. **Web Origins**: add `https://metrics-dashboard.<env>.softnethq.co.tz`
4. Save

If the client doesn't exist yet, create it per the [§ Creating the Keycloak client](../README.md#creating-the-keycloak-client-metrics-dashboard) section of the main README.

### Step 7 — Verify access

```bash
# HTTPS via Istio gateway
curl -I https://metrics-dashboard.prod.softnethq.co.tz/login
# Expected: HTTP/2 200

# Direct NodePort (for TV access — HTTP only)
curl -I http://<prod-node-ip>:32029/login
# Expected: HTTP/1.1 200 OK
```

Open in a browser:
- HTTPS: `https://metrics-dashboard.prod.softnethq.co.tz`
- Should show "Production Environment" badge in the header

Log in with the admin/viewer credentials you set in Step 2, or click "Continue with Keycloak SSO".

---

## TV Wall integration

The TV at the office shows a rotating slideshow of dashboards. Adding the prod metrics dashboard means:

1. **On the Jenkins/nginx server (`192.168.200.78`):** add a new nginx proxy port that forwards to the prod cluster's NodePort
2. **In `tv.html`:** add a new iframe slide pointing to that proxy port

The proxy is needed because nginx and the TV share the same IP, which makes browser cookies (`SameSite=Lax`) work for the iframe. See the main devsecops-platform repo's `jenkins-dashboard/` folder for the nginx config and tv.html.

Example new nginx server block (in `/opt/docker-compose/jenkins-dashboard/nginx/default.conf`):

```nginx
# Prod metrics dashboard proxy
server {
    listen 9094;
    location / {
        proxy_pass          http://<prod-node-ip>:32029;
        proxy_set_header    Host              $host;
        proxy_set_header    X-Forwarded-Proto http;
        proxy_hide_header   X-Frame-Options;
        proxy_redirect      off;
    }
}
```

And in `tv.html`:
```html
<iframe id="f5" src="http://192.168.200.78:9094/embed?token=<PROD_EMBED_TOKEN>"></iframe>
```

The `<PROD_EMBED_TOKEN>` is what you saved in Step 2.

---

## Daily operations

### Releasing a new version to prod

```bash
# In the SOURCE repo (not manifest repo)
cd ~/Desktop/metrics-dashboard

# Bump the version (or just merge dev → prod which keeps current VERSION)
git checkout prod
git merge dev
echo "1.1.0" > VERSION
git commit -am "release: 1.1.0"
git push origin prod
```

Then:
1. Jenkins detects the push, runs the prod pipeline
2. Stops at the **Production Approval** gate, sends email
3. You approve in Jenkins UI
4. Jenkins builds image `:1.1.0`, pushes to Harbor, updates `prod` branch of manifest repo
5. ArgoCD detects the manifest change within ~3 min, syncs
6. Pods rolling-restart with the new image

Total time: ~5–10 minutes from approval to live.

### Rotating the EMBED_TOKEN

```bash
NS=metrics-dashboard-prod
NEW_TOKEN=$(openssl rand -hex 32)

kubectl -n $NS patch secret dashboard-auth \
  --type=merge -p "{\"stringData\":{\"EMBED_TOKEN\":\"$NEW_TOKEN\"}}"

# Restart the deployment so pods pick up the new value
kubectl -n $NS rollout restart deployment metrics-dashboard

# Update tv.html with the new token
echo "New EMBED_TOKEN: $NEW_TOKEN"
```

The old token stops working immediately. Update tv.html → push → auto-deploy → TV updated.

### Rotating SESSION_SECRET

Same pattern. Effect: all logged-in users get kicked out and have to log in again.

```bash
kubectl -n $NS patch secret dashboard-auth \
  --type=merge -p "{\"stringData\":{\"SESSION_SECRET\":\"$(openssl rand -base64 32)\"}}"
kubectl -n $NS rollout restart deployment metrics-dashboard
```

### Rollback a bad release

ArgoCD UI → app → **History and rollback** → pick a previous Synced revision → **Rollback**

Or via CLI:
```bash
argocd app rollback metrics-dashboard-prod <revision-number>
```

You can also manually edit the prod branch of the manifest repo to revert the image tag — ArgoCD will pick it up on next sync.

---

## Troubleshooting

### Pod stuck in `ImagePullBackOff` — `x509: certificate signed by unknown authority`

Harbor TLS cert isn't trusted by the node where the pod was scheduled.

Run the [containerd cert trust setup](#1-trust-the-harbor-tls-certificate-on-every-node) on that node.

Find which node:
```bash
kubectl -n metrics-dashboard-prod get pods -o wide
```

Test from that node:
```bash
ssh administrator@<node-ip> 'sudo crictl pull harbor.devops.softnethq.co.tz/k8s_dashboard/metrics-dashboard:1.0.0'
```

If still failing after configuring `certs.d`, check **the registry config_path inside `/etc/containerd/config.toml`** — some installations have it set to `""` under `[plugins."io.containerd.grpc.v1.cri".registry]`. Set it to `"/etc/containerd/certs.d"` and restart containerd.

### ArgoCD app shows `ComparisonError` — `authentication required: HTTP Basic: Access denied`

GitLab credentials Secret is missing, has a wrong password, or the repo-server hasn't picked it up.

```bash
# Verify the Secret exists with the right label
kubectl -n argocd get secret gitlab-credentials -o yaml | grep -A2 labels

# Should contain:
#   labels:
#     argocd.argoproj.io/secret-type: repo-creds

# Restart repo-server to force re-read
kubectl -n argocd rollout restart deployment argocd-repo-server

# Then trigger a refresh of the failing app
kubectl -n argocd patch application metrics-dashboard-prod \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### The Secret keeps getting overwritten with placeholder values

You accidentally have `01-secret.example.yaml` inside the `k8s/` folder. ArgoCD syncs everything in that folder, including the example secret which has fake hashes.

```bash
# Verify on the manifest repo's prod branch (or whatever ArgoCD is syncing):
git ls-files k8s/ | grep -i secret
# Should return NOTHING — example files should live OUTSIDE the k8s/ folder
```

If the file is there, remove it from all branches:
```bash
git rm k8s/01-secret.example.yaml
git commit -m "fix: remove secret example from synced k8s/ folder"
git push origin <branch>
```

Then re-create the real secret on the cluster.

### Pod `CreateContainerConfigError — couldn't find key X in Secret dashboard-auth`

The Secret is missing a required key. List what's there:
```bash
kubectl -n metrics-dashboard-prod get secret dashboard-auth \
  -o jsonpath='{.data}' | jq 'keys'
```

Should contain: `DASHBOARD_USERS`, `SESSION_SECRET`, `EMBED_TOKEN`, `OIDC_CLIENT_SECRET`.

Patch what's missing:
```bash
kubectl -n metrics-dashboard-prod patch secret dashboard-auth \
  --type=merge -p '{"stringData":{"OIDC_CLIENT_SECRET":"<value>"}}'
```

### Pod crashes at startup with `x509: certificate signed by unknown authority` (talking to Keycloak)

Keycloak uses a self-signed/internal CA the pod doesn't trust. Two fixes:

**Quick:** set `OIDC_TLS_SKIP_VERIFY: "true"` in the configmap (already done in the default branches).

**Proper:** mount Keycloak's CA into the pod's `/etc/ssl/certs/`. Not yet implemented in this manifest — add it when Keycloak certs are fixed.

### Browser shows "your connection is not private" on `https://metrics-dashboard.prod.softnethq.co.tz`

The Istio gateway's TLS certificate isn't valid for the prod hostname. Make sure:
1. `cert-manager` is installed
2. A Certificate resource exists in `istio-system` covering `*.prod.softnethq.co.tz`
3. The Gateway references that certificate in its TLS listener

This is platform-team territory — owned by whoever manages the `main-gateway`.

### TV shows login page instead of auto-logging-in (cookies blocked)

The TV iframe must be served from the **same IP** as the page hosting it (cookie SameSite policy).

Don't link the iframe directly to the cluster IP (`http://<cluster>:32029`) — that's a different origin from the TV page (`http://192.168.200.78:9090/tv.html`). Browsers block SameSite=Lax cookies in cross-site iframes.

Instead, **proxy through nginx on the same IP** as the TV page:
```nginx
# In jenkins-dashboard/nginx/default.conf
server {
    listen 9094;
    location / {
        proxy_pass http://<cluster-node-ip>:32029;
        # ... headers
    }
}
```

Then point the iframe at `http://192.168.200.78:9094/embed?token=...` — same IP as `tv.html`, so cookies work.

### Containerd cert distribution across many nodes

Script to copy the cert + hosts.toml to every node:

```bash
NODES="production-api-1 production-data-ingestion-1 production-frontend-1"

# First fix master, then run this from master
for NODE in $NODES; do
  echo "=== $NODE ==="
  scp /etc/containerd/certs.d/harbor.devops.softnethq.co.tz/ca.crt \
      /etc/containerd/certs.d/harbor.devops.softnethq.co.tz/hosts.toml \
      administrator@$NODE:/tmp/

  ssh -t administrator@$NODE '
    sudo mkdir -p /etc/containerd/certs.d/harbor.devops.softnethq.co.tz && \
    sudo mv /tmp/ca.crt /tmp/hosts.toml /etc/containerd/certs.d/harbor.devops.softnethq.co.tz/ && \
    sudo systemctl restart containerd && \
    echo "✓ done"
  '
done
```

---

## Adapting for k8s-dashboard

The k8s-dashboard (Platform Health Dashboard) follows the **exact same deployment pattern**. The only differences:

| Aspect | metrics-dashboard | k8s-dashboard |
|---|---|---|
| **Manifest repo** | `kubernetes-manifest/metrics-dashboard.git` | `kubernetes-manifest/k8s-dashboard-manifest.git` |
| **Source repo** | `devsecops1/metrics-dashboard.git` | `devsecops1/k8s-dashboard.git` |
| **Harbor image** | `harbor.../k8s_dashboard/metrics-dashboard` | `harbor.../k8s_dashboard/k8s-dashboard` |
| **Target namespace** | `metrics-dashboard-prod` | `k8s-dashboard` |
| **Secret name** | `dashboard-auth` | `dashboard-secrets` |
| **Secret keys** | `DASHBOARD_USERS`, `SESSION_SECRET`, `EMBED_TOKEN`, `OIDC_CLIENT_SECRET` | `DASHBOARD_SECRET`, `ADMIN_USER`/`PASS`, `VIEWER_USER`/`PASS`, `SMTP_PASSWORD`, `EMBED_TOKEN`, `OIDC_CLIENT_SECRET` |
| **NodePort (prod)** | `32029` | `31290` |
| **Hostname (prod)** | `metrics-dashboard.prod.softnethq.co.tz` | `k8s-dashboard.prod.softnethq.co.tz` |
| **Data source** | Prometheus (PromQL) | Kubernetes API (client-go) |
| **Cluster-scoped resources** | None | **ClusterRole + ClusterRoleBinding + ServiceAccount with cluster-wide read RBAC** ⚠️ |

**⚠️ The cluster-scoped resources caveat:** Because k8s-dashboard needs to list pods/deployments across all namespaces, it has a `ClusterRoleBinding`. Cluster-scoped resources have unique names cluster-wide — you can't have two `ClusterRoleBinding`s with the same name. This means:

- **On a fresh cluster (like prod):** deploying ArgoCD-managed k8s-dashboard works fine.
- **On a cluster that already has a manually-deployed k8s-dashboard (like the current dev cluster):** the ArgoCD-managed one would conflict with the existing `k8s-dashboard-reader` ClusterRoleBinding. Either:
  - Delete the manual deployment first, then let ArgoCD adopt the cluster-scoped resources, OR
  - Rename the cluster-scoped resources per-environment (e.g., `k8s-dashboard-dev-reader`) — requires editing the dev branch.

For now, **only prod uses ArgoCD for k8s-dashboard**. Dev cluster keeps the manually-deployed one.

Secret creation for k8s-dashboard (use this instead of the metrics one in Step 2):

```bash
DASHBOARD_SECRET=$(openssl rand -hex 32)
EMBED_TOKEN=$(openssl rand -hex 32)

kubectl create secret generic dashboard-secrets -n k8s-dashboard \
  --from-literal=DASHBOARD_SECRET="$DASHBOARD_SECRET" \
  --from-literal=ADMIN_USER="admin" \
  --from-literal=ADMIN_PASS="<strong-prod-admin-password>" \
  --from-literal=VIEWER_USER="viewer" \
  --from-literal=VIEWER_PASS="<strong-prod-viewer-password>" \
  --from-literal=SMTP_PASSWORD="<gmail-app-password>" \
  --from-literal=EMBED_TOKEN="$EMBED_TOKEN" \
  --from-literal=OIDC_CLIENT_SECRET="<keycloak-client-secret>"
```

Everything else (containerd cert trust, ArgoCD setup, GitLab credentials, Keycloak client, DNS, TV wall integration) is identical.
