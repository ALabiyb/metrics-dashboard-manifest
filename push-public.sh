#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Author: Labiyb M. Said — DevSecOps Engineer
# Contact: saidlabiybm@gmail.com
# ---------------------------------------------------------------------------
# Push a NexBridge-branded version of this repo's main branch to GitHub.
# Run after committing your changes on GitLab (origin/main).
# GitLab stays SoftNet; GitHub gets NexBridge Technologies branding.
set -euo pipefail

TEMP="public-push-$(date +%s)"
git checkout main
git checkout -b "$TEMP"

# Files containing internal branding / hostnames
FILES=(
  k8s/01-configmap.yaml
  k8s/02-deployment.yaml
  k8s/03-service.yaml
  k8s/04-httproute.yaml
  argocd/metrics-dashboard-dev.yaml
  argocd/metrics-dashboard-uat.yaml
  argocd/metrics-dashboard-prod.yaml
  README.md
)

# Only process files that actually exist on this branch
EXISTING=()
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] && EXISTING+=("$f")
done

perl -pi -e '
  s/SoftNet HQ/NexBridge HQ/g;
  s/SoftNet Technologies/NexBridge Technologies/g;
  s/SoftNet%20AD/NexBridge%20AD/g;
  s/SoftNet AD/NexBridge AD/g;
  s/softnethq\.co\.tz/nexbridge.co.tz/g;
  s|http://192\.168\.15\.\d+/kubernetes-manifest/metrics-dashboard\.git|https://github.com/ALabiyb/metrics-dashboard-manifest.git|g;
  s/192\.168\.200\.\d+/<k8s-api-server>/g;
  s/192\.168\.15\.\d+/<internal-ip>/g;
  s/lsaid\@softnet\.co\.tz/admin\@nexbridge.co.tz/g;
  s/lsaid/CHANGE_ME_credentials_id/g;
' "${EXISTING[@]}"

git add "${EXISTING[@]}"
git commit -m "public: NexBridge Technologies branding for GitHub"
git push github "$TEMP":main --force
git checkout main
git branch -D "$TEMP"

echo "Done — github/main updated with NexBridge branding."
