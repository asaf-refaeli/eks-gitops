# platform

GitOps repository for the EKS `platform` cluster. **Argo CD is the only thing
that applies manifests to the cluster.** After the one-time bootstrap below, the
workflow is: change Git → Argo CD reconciles. No `kubectl apply`.

---

## Layout

```
bootstrap/                  synced by the root Application (recursively)
├── root.yaml               the ONE `kubectl apply` — the GitOps seed
├── projects/
│   ├── platform.yaml       AppProject: platform  (Argo CD config + shared tooling)
│   └── apps.yaml           AppProject: apps      (empty placeholder for real workloads)
└── applicationsets/
    └── platform.yaml       discovers workloads/* → one Application each, in project 'platform'

workloads/                  one directory per Application — Kustomize or Helm, per folder
├── argocd/                 [kustomize] two config keys in argocd-cm / argocd-rbac-cm (see caveat)
├── kubernetes-dashboard/   [kustomize] the example app — proves the reconcile loop end to end
├── external-secrets/       [helm] External Secrets Operator, upstream chart pinned at 2.10.0
└── aws-load-balancer-controller/  [helm] AWS Load Balancer Controller, chart pinned at 3.5.0

scripts/bootstrap.sh        thin wrapper around the one apply + a readiness wait
```

## How it fits together

```
kubectl apply bootstrap/root.yaml
        │
        ▼
  Application/root ──sync──► bootstrap/  (recurse)
        │
        ├─► AppProject/platform      (sync-wave -1, created first)
        ├─► AppProject/apps          (sync-wave -1)
        └─► ApplicationSet/platform  (sync-wave 0)
                │  git directories generator: workloads/*
                ├─► Application/argocd                → workloads/argocd/
                ├─► Application/kubernetes-dashboard  → workloads/kubernetes-dashboard/
                ├─► Application/external-secrets      → workloads/external-secrets/
                └─► Application/aws-load-balancer-controller → workloads/aws-load-balancer-controller/
```

`root` is inside the path it syncs, so Argo CD adopts and self-heals it from
Git too. Every generated Application uses `automated` sync with `prune` +
`selfHeal`, plus `CreateNamespace=true`, `ServerSideApply=true`, `PruneLast=true`.

The generator does not care how a folder is rendered: Argo CD picks Kustomize or
Helm per directory based on whether it finds a `kustomization.yaml` or a
`Chart.yaml`. `ServerSideApply=true` also matters for Helm charts with large
CRDs — it avoids the `metadata.annotations: Too long` failure that
client-side apply hits on the External Secrets CRDs.

## Prerequisites (one-time cluster setup)

1. **This repo must be reachable by Argo CD's repo-server.** It is currently
   private and no repository credential is configured in Argo CD. Add one (a
   one-time infra step, like the bootstrap apply itself):

   ```bash
   argocd repo add https://github.com/asaf-refaeli/platform.git \
     --username <github-user> --password <github-PAT>
   ```

   (Or apply a `Secret` labeled `argocd.argoproj.io/secret-type: repository`.
   Do not commit credentials to this repo.)

2. **The repo-server needs egress to any upstream Helm chart repo** used by a
   workload — currently `https://charts.external-secrets.io` and
   `https://aws.github.io/eks-charts`. Argo CD runs
   `helm dependency build` itself; it just needs to reach the repo. An
   air-gapped cluster would vendor the dependency into
   `workloads/external-secrets/charts/` instead.

3. **`root.yaml` and the ApplicationSet track `targetRevision: main`.** Merge
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

## External Secrets Operator

Installed from the upstream chart (pinned at 2.10.0 / appVersion v2.10.0) into
the `external-secrets` namespace. Verify:

```bash
kubectl -n external-secrets get pods     # controller, webhook, cert-controller
kubectl get crd | grep external-secrets  # ExternalSecret, SecretStore, ...
```

This installs **the operator only**. It does nothing on its own until you give
it a backend: a `SecretStore` / `ClusterSecretStore` pointing at AWS Secrets
Manager (or similar), which on EKS also means an IRSA role for the operator's
ServiceAccount. That is deliberately a separate change — it needs real AWS
identity decisions rather than a default.

## AWS Load Balancer Controller

Installed from the upstream chart (pinned at 3.5.0 / appVersion v3.5.0) into the
`aws-load-balancer-controller` namespace. It also creates the `alb`
`IngressClass` and its `IngressClassParams`. Verify:

```bash
kubectl -n aws-load-balancer-controller get pods
kubectl get ingressclass alb
kubectl get crd | grep elbv2.k8s.aws     # TargetGroupBinding, IngressClassParams
```

**`clusterName: platform` is mandatory** — the chart refuses to render without
it, and the controller uses it to discover and tag AWS resources. If the cluster
is ever rebuilt under a different name, this value must change with it.

**AWS auth is via EKS Pod Identity**, configured out-of-band — deliberately not
in this repo, since it is IAM rather than Kubernetes. Two things must exist
before the controller can actually provision load balancers:

1. The **EKS Pod Identity Agent** addon installed on the cluster.
2. A **Pod Identity association** binding an IAM role (carrying
   `AWSLoadBalancerControllerIAMPolicy`) to:
   - namespace `aws-load-balancer-controller`
   - serviceAccount `aws-load-balancer-controller`

That ServiceAccount name is pinned in `values.yaml` precisely so the association
cannot be broken by a chart naming change. Without the association the
controller installs and runs, but logs AWS permission errors and provisions
nothing.

Subnets must also carry the usual discovery tags — `kubernetes.io/role/elb` on
public subnets, `kubernetes.io/role/internal-elb` on private ones.

## Prove the GitOps loop

**Drift correction (no commit):**

```bash
kubectl -n kubernetes-dashboard scale deploy/kubernetes-dashboard --replicas=0
# selfHeal restores it to 1 within ~3 min
```

**Change via Git:** edit anything under `workloads/kubernetes-dashboard/`,
commit, push — Argo CD applies it on the next poll (~3 min) or on a manual
refresh.

## Add another app

1. `mkdir workloads/<name>/`
2. Either a `kustomization.yaml` (manifests / remote bases) **or** a `Chart.yaml`
   + `values.yaml` (a wrapper chart around an upstream one, as
   `external-secrets/` does). Argo CD detects which from the files present.
3. Commit and push.

The `platform` ApplicationSet creates the Application automatically. Namespace
defaults to `<name>`; the project allows any namespace on this cluster, so no
project edit is needed for that.

The one thing that *does* need a deliberate project edit: if `<name>` uses
cluster-scoped kinds beyond those already allowed (`Namespace`, `ClusterRole`,
`ClusterRoleBinding`, `CustomResourceDefinition`,
`ValidatingWebhookConfiguration`), add them to `clusterResourceWhitelist` in
`bootstrap/projects/platform.yaml` — otherwise the sync fails with
`resource <Kind> is not permitted in project platform`.

When real application workloads (as opposed to platform tooling) arrive, give
them their own project by filling in `bootstrap/projects/apps.yaml` and pointing
their Applications at `project: apps`.

## Caveat: Argo CD config is "config-only"

Argo CD itself was installed with the **Helm chart** `argo-cd` v10.4.2
(appVersion v3.5.2), release `argo-cd`. This repo does **not** manage that
install. `workloads/argocd/` declares only two keys:

| ConfigMap        | Key                                    | Value           |
|------------------|----------------------------------------|-----------------|
| `argocd-cm`      | `application.resourceTrackingMethod`   | `annotation`    |
| `argocd-rbac-cm` | `policy.default`                        | `role:readonly` |

Both ConfigMaps are otherwise `managed-by: Helm`. Because the Application syncs
with `ServerSideApply=true`, Git owns **only those two fields**; Helm keeps the
rest. A future `helm upgrade` of the chart may report a field-manager conflict
on those keys — resolve it by setting the same values in the chart's
`configs.cm` / `configs.rbac` values, or drop these two files if you move Argo
CD fully under Helm.

## Recovery

If the root / projects / ApplicationSet get into a bad state, re-run the
bootstrap — it's idempotent:

```bash
kubectl apply -f bootstrap/root.yaml
```

## Deliberately out of scope

Ingress/TLS/LoadBalancer, SSO/OIDC, multiple environments, Argo CD
Notifications, secrets management (sealed/external secrets), image updater,
network policies. All reasonable next steps; none needed to demonstrate a
correct GitOps setup.
