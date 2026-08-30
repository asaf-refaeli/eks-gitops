# platform

GitOps repository for the EKS `platform` cluster. **Argo CD is the only thing
that applies manifests to the cluster.** After the one-time bootstrap below, the
workflow is: change Git → Argo CD reconciles. No `kubectl apply`.

> **Variant:** this branch uses **Helm** (not Kustomize) for workloads and the
> **app-of-apps** pattern (not an ApplicationSet) for wiring. Everything else —
> the bootstrap seed, the two AppProjects, config-only Argo CD, the Kubernetes
> Dashboard v2.7.0 example on ClusterIP + port-forward — is the same.

---

## Layout

```
bootstrap/                  synced by the root Application (recursively)
├── root.yaml               the ONE `kubectl apply` — the GitOps seed
├── projects/
│   ├── platform.yaml       AppProject: platform  (Argo CD config + shared tooling)
│   └── apps.yaml           AppProject: apps      (empty placeholder for real workloads)
└── apps/                   one child Application manifest per workload (app-of-apps)
    ├── argocd.yaml
    └── kubernetes-dashboard.yaml

workloads/                  one Helm chart per Application
├── argocd/                 local chart: two config keys in argocd-cm / argocd-rbac-cm
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/{argocd-cm,argocd-rbac-cm}.yaml
└── kubernetes-dashboard/   wrapper chart: upstream dashboard dep + read-only viewer
    ├── Chart.yaml          dependency: kubernetes-dashboard 6.0.8 (appVersion 2.7.0)
    ├── values.yaml
    └── templates/{viewer-serviceaccount,viewer-clusterrolebinding}.yaml

scripts/bootstrap.sh        thin wrapper around the one apply + a readiness wait
```

## How it fits together

```
kubectl apply bootstrap/root.yaml
        │
        ▼
  Application/root ──sync──► bootstrap/  (recurse)
        │
        ├─► AppProject/platform               (sync-wave -1, created first)
        ├─► AppProject/apps                   (sync-wave -1)
        ├─► Application/argocd                → workloads/argocd/               (Helm)
        └─► Application/kubernetes-dashboard  → workloads/kubernetes-dashboard/ (Helm)
```

`root` is inside the path it syncs, so Argo CD adopts and self-heals it from
Git too. Adding an app means adding **two** files: the chart under `workloads/`
and a child `Application` under `bootstrap/apps/` (this is the app-of-apps
trade-off vs an ApplicationSet, which would discover the folder automatically).

Every Application uses `automated` sync with `prune` + `selfHeal`, plus
`CreateNamespace=true`, `ServerSideApply=true`, `PruneLast=true`.

## Prerequisites (one-time cluster setup)

1. **This repo must be reachable by Argo CD's repo-server.** It is currently
   private and no repository credential is configured in Argo CD. Add one (a
   one-time infra step, like the bootstrap apply itself):

   ```bash
   argocd repo add https://github.com/asaf-refaeli/platform.git \
     --username <github-user> --password <github-PAT>
   ```

2. **The repo-server needs egress to the Helm chart repo**
   (`https://kubernetes.github.io/dashboard/`). Argo CD runs
   `helm dependency build` for the wrapper chart automatically; it just needs to
   reach the repo. Air-gapped clusters would vendor the dependency into
   `workloads/kubernetes-dashboard/charts/` instead.

3. **`root.yaml` and the child Applications track `targetRevision: main`.** Merge
   this branch to `main` before bootstrapping, or temporarily point them at your
   branch for a dry run.

## Bootstrap (once)

```bash
./scripts/bootstrap.sh
# or just:  kubectl apply -f bootstrap/root.yaml
```

Then watch it converge:

```bash
kubectl -n argocd get applications -w
```

Expect `root`, `argocd`, `kubernetes-dashboard` → **Synced / Healthy**.

## Verify the example app

```bash
kubectl -n kubernetes-dashboard get pods          # dashboard + metrics-scraper Running
kubectl -n kubernetes-dashboard create token viewer
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
# browse https://localhost:8443 and paste the token
```

`viewer` is a read-only identity (built-in `view` ClusterRole — no Secrets).

## Prove the GitOps loop

**Drift correction (no commit):**

```bash
kubectl -n kubernetes-dashboard scale deploy/kubernetes-dashboard --replicas=0
# selfHeal restores it within ~3 min
```

**Change via Git:** edit `workloads/kubernetes-dashboard/values.yaml` (e.g.
`kubernetes-dashboard.replicaCount: 2`), commit, push — Argo CD applies it on
the next poll (~3 min) or on a manual refresh.

## Add another app

1. `workloads/<name>/` — a Helm chart (`Chart.yaml`, `values.yaml`, `templates/`
   or a `dependencies:` wrapper).
2. `bootstrap/apps/<name>.yaml` — a child `Application` pointing `source.path` at
   that folder, `project: platform`.
3. Commit and push.

If `<name>` needs cluster-scoped kinds beyond `ClusterRole`/`ClusterRoleBinding`,
add them to `clusterResourceWhitelist` in `bootstrap/projects/platform.yaml`.
When real application workloads arrive, fill in `bootstrap/projects/apps.yaml`
and point their Applications at `project: apps`.

## Caveat: Argo CD config is "config-only"

Argo CD itself was installed with the **Helm chart** `argo-cd` v10.4.2
(appVersion v3.5.2), release `argo-cd`. This repo does **not** manage that
install. `workloads/argocd/` renders only two keys:

| ConfigMap        | Key                                    | Value           |
|------------------|----------------------------------------|-----------------|
| `argocd-cm`      | `application.resourceTrackingMethod`   | `annotation`    |
| `argocd-rbac-cm` | `policy.default`                       | `role:readonly` |

Both ConfigMaps are otherwise `managed-by: Helm`. Because the Application syncs
with `ServerSideApply=true`, Git owns **only those two fields**; Helm keeps the
rest. A future `helm upgrade` of the `argo-cd` chart may report a field-manager
conflict on those keys — resolve it by setting the same values in the chart's
`configs.cm` / `configs.rbac` values.

## Recovery

If the root / projects / child Applications get into a bad state, re-run the
bootstrap — it's idempotent:

```bash
kubectl apply -f bootstrap/root.yaml
```

## Deliberately out of scope

Ingress/TLS/LoadBalancer, SSO/OIDC, multiple environments, Argo CD
Notifications, secrets management, image updater, network policies. All
reasonable next steps; none needed to demonstrate a correct GitOps setup.
