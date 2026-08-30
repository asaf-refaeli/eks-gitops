#!/usr/bin/env bash
# The one and only imperative step for this repo. Everything after this is
# GitOps: change Git, let Argo CD reconcile.
set -euo pipefail

cd "$(dirname "$0")/.."

echo ">> Applying the root Application (the GitOps seed)..."
kubectl apply -f bootstrap/root.yaml

echo ">> Waiting for Argo CD to be ready..."
kubectl -n argocd rollout status deploy/argo-cd-argocd-server --timeout=120s || true

cat <<'EOF'

>> Done. Watch it converge:

   kubectl -n argocd get applications -w

Expect: root, argocd, kubernetes-dashboard -> Synced / Healthy.

Then open the Dashboard:

   kubectl -n kubernetes-dashboard create token viewer
   kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
   # browse https://localhost:8443 and paste the token

EOF
