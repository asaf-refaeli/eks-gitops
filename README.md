# eks-gitops

GitOps repository for the EKS `platform` cluster. **Argo CD is the only thing
that applies manifests to the cluster.** After the one-time bootstrap below, the
workflow is: change Git → Argo CD reconciles. No `kubectl apply`.

---

## Layout

```
bootstrap/                  synced by the root Application (recursively)
├── root.yaml               the ONE `kubectl apply` — the GitOps seed
├── projects/
│   ├── platform.yaml       AppProject: platform    (Argo CD config + shared tooling)
│   └── sample-app.yaml     AppProject: sample-app  (scoped to one namespace + two repos)
├── applicationsets/
│   └── platform.yaml       discovers workloads/platform/* → one Application each, in project 'platform'
└── apps/
    └── sample-app.yaml     Application: chart from the sample-nodejs repo + values from this repo

workloads/
├── platform/               shared tooling; one directory per Application — Kustomize or Helm
│   ├── argocd/                       [kustomize] two config keys in argocd-cm / argocd-rbac-cm (see caveat)
│   ├── kubernetes-dashboard/         [kustomize] the example app — proves the reconcile loop end to end
│   ├── external-secrets/             [helm] External Secrets Operator, upstream chart pinned at 2.10.0
│   ├── aws-load-balancer-controller/ [helm] ALB controller, upstream chart pinned at 3.5.0
│   ├── external-dns/                 [kustomize] namespace + ServiceAccount only
│   └── sitelens-config/              [kustomize] config for the sitelens app — deploys into ns `sitelens`
└── apps/                   application workloads; values only, the chart lives in the app's repo
    └── sample-app/
        └── values.yaml     environment values (image, ingress); CI sets image.tag

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
        ├─► AppProject/sample-app    (sync-wave -1)
        ├─► ApplicationSet/platform  (sync-wave 0)
        │       │  git directories generator: workloads/platform/*
        │       ├─► Application/argocd                → workloads/platform/argocd/
        │       ├─► Application/kubernetes-dashboard  → workloads/platform/kubernetes-dashboard/
        │       ├─► Application/external-secrets      → workloads/platform/external-secrets/
        │       ├─► Application/aws-load-balancer-controller → workloads/platform/aws-load-balancer-controller/
        │       ├─► Application/external-dns          → workloads/platform/external-dns/
        │       └─► Application/sitelens-config       → workloads/platform/sitelens-config/   (ns: sitelens)
        └─► Application/sample-app   (sync-wave 1, project sample-app, ns sample-app)
                ├─ source: sample-nodejs.git  path chart/            (Helm chart)
                └─ source: platform.git       ref values  →  $values/workloads/apps/sample-app/values.yaml
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
   argocd repo add https://github.com/asaf-refaeli/eks-gitops.git \
     --username <github-user> --password <github-PAT>
   ```

   (Or apply a `Secret` labeled `argocd.argoproj.io/secret-type: repository`.
   Do not commit credentials to this repo.)

2. **The repo-server needs egress to any upstream Helm chart repo** used by a
   workload — currently `https://charts.external-secrets.io` and
   `https://aws.github.io/eks-charts`. Argo CD runs
   `helm dependency build` itself; it just needs to reach the repo. An
   air-gapped cluster would vendor the dependency into
   `workloads/platform/external-secrets/charts/` instead.

   The sample-app chart comes from `https://github.com/asaf-refaeli/sample-nodejs.git`,
   which is public, so it needs no repository credential.

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

**`region` and `vpcId` are effectively mandatory too.** Both are nominally
auto-discovered from EC2 IMDS, but the node launch template's IMDS hop limit
stops pods on the pod network from reaching `169.254.169.254`. Without them the
controller exits at startup with `failed to introspect vpcID` and crashloops.
Re-derive `vpcId` after any cluster rebuild:

```bash
aws eks describe-cluster --name platform --region il-central-1 \
  --query cluster.resourcesVpcConfig.vpcId
```

**`defaultTargetType: ip`** registers pod IPs directly as load balancer targets
through the VPC CNI, instead of routing via a NodePort on each instance (the
chart's default). Fewer hops, and required for pod readiness gates.

**The service mutator webhook is left enabled** (chart default). Be aware it is
cluster-wide and fail-closed on Service **creation**: `failurePolicy: Fail`,
no namespace selector, `rules: services/CREATE`. If the controller is
unavailable, no new Service can be created anywhere in the cluster — worth
remembering during a rebuild. It is what makes an un-annotated
`type: LoadBalancer` Service resolve to an NLB via this controller rather than a
legacy Classic ELB; set `enableServiceMutatorWebhook: false` if you would rather
annotate LoadBalancer Services explicitly and drop the dependency.

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

**All `alb` Ingresses share one ALB.** `ingressClassParams.spec.group.name:
shared` puts every Ingress with `ingressClassName: alb` into one IngressGroup, so
apps do not get an ALB each (each ALB has a fixed hourly cost). It is set on the
class, so the platform decides the grouping and an Ingress cannot choose another
group. Each app needs a unique host; settings such as `scheme` and listen ports
must agree across the group, and a broken Ingress stalls updates to the whole
ALB (controller logs: `failed to build LoadBalancer configuration`). Verify:

```bash
kubectl get ingressclassparams alb -o jsonpath='{.spec.group.name}'   # shared
kubectl get ingress -A                                                # same ADDRESS for every alb Ingress
```

## sample-app

The first application workload: a Node.js demo app. The Helm chart lives in the
app repo (`sample-nodejs/chart/`), so code and chart change in one PR. This repo
holds only what is deployed: the environment values, including `image.tag`.

- `bootstrap/apps/sample-app.yaml` is a multi-source Application. Source one is
  the chart; source two is this repo with `ref: values`, which only exposes
  `$values/workloads/apps/sample-app/values.yaml` to the first source.
- Project `sample-app` allows only those two repos and namespace `sample-app`.
  A resource in any other namespace fails the sync with
  `namespace <ns> is not permitted in project 'sample-app'`.
- Argo CD creates the namespace (`CreateNamespace=true`) and labels it
  `pod-security.kubernetes.io/enforce: restricted`, so the API server rejects
  pods that do not meet the restricted Pod Security profile.
- Exposed at `https://sample-app.asafr.dev` on the shared ALB, with only the
  public paths (`/my-app`, `/about`). The ACM certificate is found from the
  host; the ALB health-checks `/ready`.
- CI in `sample-nodejs` builds the image, pushes it to ECR, and commits the new
  `image.tag` to `workloads/apps/sample-app/values.yaml`. That commit is the
  deploy; `git revert` is the rollback.

Verify:

```bash
kubectl -n argocd get application sample-app      # Synced / Healthy
kubectl -n sample-app get pods,svc,ingress
curl https://sample-app.asafr.dev/my-app          # Hello, World!
```

## Prove the GitOps loop

**Drift correction (no commit):**

```bash
kubectl -n kubernetes-dashboard scale deploy/kubernetes-dashboard --replicas=0
# selfHeal restores it to 1 within ~3 min
```

**Change via Git:** edit anything under `workloads/platform/kubernetes-dashboard/`,
commit, push — Argo CD applies it on the next poll (~3 min) or on a manual
refresh.

## Add platform tooling

1. `mkdir workloads/platform/<name>/`
2. Either a `kustomization.yaml` (manifests / remote bases) **or** a `Chart.yaml`
   + `values.yaml` (a wrapper chart around an upstream one, as
   `external-secrets/` does). Argo CD detects which from the files present.
3. Commit and push.

The `platform` ApplicationSet creates the Application automatically, named
after the folder. The destination namespace is that folder name **minus a
`-config` suffix**:

| folder | Application | namespace |
|---|---|---|
| `external-dns/` | `external-dns` | `external-dns` |
| `sitelens-config/` | `sitelens-config` | `sitelens` |

So a folder holding config *for another app* can be named after that app
without hijacking its namespace, and two folders can target one namespace —
`sitelens-config/` and a future `sitelens/` both deploy into `sitelens`. Any
folder not ending in `-config` behaves exactly as before. The project allows
any namespace on this cluster, so no project edit is needed for that.

The one thing that *does* need a deliberate project edit: if `<name>` uses
cluster-scoped kinds beyond those already allowed (`Namespace`, `ClusterRole`,
`ClusterRoleBinding`, `CustomResourceDefinition`,
`ValidatingWebhookConfiguration`), add them to `clusterResourceWhitelist` in
`bootstrap/projects/platform.yaml` — otherwise the sync fails with
`resource <Kind> is not permitted in project platform`.

## Add an application

Follow the sample-app pattern: the chart stays in the app's repo, and this repo
gets three files.

1. `bootstrap/projects/<name>.yaml`: an AppProject allowing the app repo, this
   repo, and namespace `<name>` only.
2. `workloads/apps/<name>/values.yaml`: environment values. Use
   `ingressClassName: alb` with a unique host; the shared ALB picks it up.
3. `bootstrap/apps/<name>.yaml`: a multi-source Application like
   `sample-app.yaml`, in project `<name>`, with sync-wave `1`.

Root syncs `bootstrap/` recursively, so committing these is enough. With several
applications, an ApplicationSet over `workloads/apps/*` would replace the
copied Application files.

## Caveat: Argo CD config is "config-only"

Argo CD itself was installed with the **Helm chart** `argo-cd` v10.4.2
(appVersion v3.5.2), release `argo-cd`. This repo does **not** manage that
install. `workloads/platform/argocd/` declares only two keys:

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

SSO/OIDC, multiple environments, Argo CD
Notifications, secrets management (sealed/external secrets), image updater,
network policies. All reasonable next steps; none needed to demonstrate a
correct GitOps setup.
