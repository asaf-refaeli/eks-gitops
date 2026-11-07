# eks-gitops

GitOps repository for the EKS `platform` cluster. Argo CD is the only thing
that applies manifests to the cluster. After a one-time bootstrap, you change
Git and Argo CD reconciles. Nobody runs `kubectl apply`.

## Architecture

```
            Internet
               │  *.asafr.dev (Route 53, alias records by ExternalDNS)
               ▼
   ALB (internet-facing, public subnets, 3 AZs)
   :80 → redirect to :443   :443 TLS with ACM cert
               │  ip targets (pod IPs via VPC CNI)
               ▼
   EKS "platform" ── managed node group, private subnets, 3 AZs
               │
               ├─► NAT gateway → Internet (images, Helm repos)
               ├─► ECR (app images)
               └─► AWS Secrets Manager (via External Secrets)
```

| Area | Setup |
|---|---|
| Region | `il-central-1`, 3 availability zones |
| VPC | `10.0.0.0/16` with three subnet tiers per AZ: public (ALB, NAT), private (nodes), isolated (reserved for databases, no internet route). One NAT gateway. S3 gateway endpoint. |
| EKS | Kubernetes 1.36, API endpoint public and private, access entries (`API` auth mode) |
| Nodes | One managed node group, `t3.medium` on-demand, Amazon Linux 2023, 3 nodes |
| EKS add-ons | `vpc-cni`, `kube-proxy`, `coredns`, `metrics-server`, `eks-pod-identity-agent`, `external-dns` |
| AWS access from pods | EKS Pod Identity for the AWS Load Balancer Controller, ExternalDNS and External Secrets |
| Ingress | AWS Load Balancer Controller, one shared internet-facing ALB for every `alb` Ingress |
| TLS | ACM certificate for `asafr.dev` and `*.asafr.dev`, DNS-validated, picked by Ingress host |
| DNS | Public Route 53 zone `asafr.dev`. ExternalDNS (EKS add-on) creates alias records from Ingresses and Services, with `upsert-only` policy and TXT ownership records. |
| Images | ECR, immutable tags |
| Secrets | AWS Secrets Manager, synced into the cluster by External Secrets Operator |
| GitOps | Argo CD (installed with Helm, see the caveat below) |

The VPC, EKS cluster, node group, add-ons, IAM roles, ACM certificate and
Route 53 zone are created outside this repo. This repo manages what runs inside
the cluster.

### How a request reaches a pod

1. A client resolves `sample-app.asafr.dev`. ExternalDNS created that record as
   an alias to the shared ALB when the Ingress appeared.
2. The ALB redirects HTTP to HTTPS and terminates TLS with the wildcard ACM
   certificate. The controller finds the certificate by matching the Ingress
   host.
3. The ALB matches the host and path rules from the Ingress and forwards to the
   pod IPs directly (`target-type: ip`). Requests that match no rule get the
   listener's fixed default response.
4. Pods run on nodes in the private subnets. They reach the internet only
   outbound, through the NAT gateway.

### How a deploy works

1. CI in the app repo builds an image and pushes it to ECR. Tags are immutable,
   so a tag always points to the same image.
2. CI commits the new `image.tag` to `workloads/apps/<app>/values.yaml` here.
3. Argo CD sees the commit and syncs. Nodes pull the image from ECR.

Platform changes skip steps 1 and 2: you edit `workloads/platform/` and Argo CD
does the rest.

### Trade-offs

This is a single-environment cluster sized for cost:

- One NAT gateway for all three AZs. If its AZ goes down, nodes in the other
  AZs lose outbound internet access, but existing inbound traffic through the
  ALB keeps working.
- Three `t3.medium` nodes. External Secrets runs one replica per component, and
  the Helm-installed components have small resource limits.
- One ALB for every app. This keeps the hourly cost flat, but all apps share
  its listener settings and one broken Ingress blocks updates for the rest (see
  [AWS Load Balancer Controller](#aws-load-balancer-controller)).
- Control plane logging is off.

## Layout

```
bootstrap/                  synced recursively by the root Application
├── root.yaml               the one `kubectl apply` (the GitOps seed)
├── projects/
│   ├── platform.yaml       AppProject for Argo CD config and shared tooling
│   └── sample-app.yaml     AppProject limited to one namespace and two repos
├── applicationsets/
│   └── platform.yaml       one Application per workloads/platform/* folder
└── apps/
    └── sample-app.yaml     chart from the sample-nodejs repo, values from this repo

workloads/
├── platform/                         one folder per Application, Kustomize or Helm
│   ├── argocd/                       [kustomize] two keys in argocd-cm / argocd-rbac-cm
│   ├── kubernetes-dashboard/         [kustomize] example app for testing the reconcile loop
│   ├── external-secrets/             [helm] External Secrets Operator 2.10.0 + ClusterSecretStore
│   ├── aws-load-balancer-controller/ [helm] AWS Load Balancer Controller 3.5.0
│   └── external-dns/                 [kustomize] namespace and ServiceAccount for the EKS add-on
└── apps/
    └── sample-app/values.yaml        environment values; CI sets image.tag

scripts/bootstrap.sh        runs the one apply, then waits for Argo CD
```

## How it fits together

```
kubectl apply -f bootstrap/root.yaml
        │
        ▼
  Application/root ──sync──► bootstrap/ (recursive)
        ├─► AppProject/platform, AppProject/sample-app   (sync-wave -1)
        ├─► ApplicationSet/platform                      (sync-wave 0)
        │       └─► one Application per workloads/platform/<name>/
        └─► Application/sample-app                       (sync-wave 1)
                ├─ source: sample-nodejs.git, path chart/
                └─ source: eks-gitops.git, ref values → workloads/apps/sample-app/values.yaml
```

- `root.yaml` sits inside the path it syncs, so Argo CD also manages and
  self-heals `root` from Git.
- Every Application syncs automatically with `prune` and `selfHeal`, plus
  `CreateNamespace=true`, `ServerSideApply=true` and `PruneLast=true`.
- Argo CD renders a folder with Kustomize if it has a `kustomization.yaml` and
  with Helm if it has a `Chart.yaml`. The ApplicationSet treats both the same.
- `ServerSideApply=true` avoids the `metadata.annotations: Too long` error that
  client-side apply hits on the large External Secrets CRDs.

## Prerequisites

This repo and `asaf-refaeli/sample-nodejs` are public, so Argo CD needs no
repository credential.

1. **The repo-server needs egress to the upstream Helm repos**
   `https://charts.external-secrets.io` and `https://aws.github.io/eks-charts`.
   Argo CD runs `helm dependency build` itself. On an air-gapped cluster, vendor
   the charts into each wrapper chart's `charts/` folder instead.

2. **`root.yaml` and the ApplicationSet track `main`.** To try a branch, point
   their `targetRevision` / `revision` at it first.

## Bootstrap (once)

```bash
./scripts/bootstrap.sh          # or: kubectl apply -f bootstrap/root.yaml
kubectl -n argocd get applications -w
```

Wait until every Application shows Synced / Healthy. Then check the example app:

```bash
kubectl -n kubernetes-dashboard get pods          # dashboard + metrics-scraper Running
kubectl -n kubernetes-dashboard create token viewer
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
# browse https://localhost:8443 and paste the token
```

`viewer` is bound to the built-in `view` ClusterRole, so it is read-only and
cannot read Secrets.

To recover from a broken root, project or ApplicationSet, apply `root.yaml`
again. It is idempotent.

## External Secrets Operator

Upstream chart 2.10.0 (appVersion v2.10.0) in namespace `external-secrets`. The
wrapper chart also creates a ClusterSecretStore, `aws-secrets-manager`, that
reads from AWS Secrets Manager in `il-central-1`. It has no `auth` block, so the
operator uses its own EKS Pod Identity association, which is set up outside
this repo.
To use it, point an ExternalSecret's `secretStoreRef` at
`kind: ClusterSecretStore`, `name: aws-secrets-manager`.

```bash
kubectl -n external-secrets get pods            # controller, webhook, cert-controller
kubectl get clustersecretstore aws-secrets-manager
```

## AWS Load Balancer Controller

Upstream chart 3.5.0 (appVersion v3.5.0) in namespace
`aws-load-balancer-controller`. It also creates the `alb` IngressClass and its
IngressClassParams.

```bash
kubectl -n aws-load-balancer-controller get pods
kubectl get ingressclass alb
kubectl get crd | grep elbv2.k8s.aws     # TargetGroupBinding, IngressClassParams
```

**Required values.** These must change if the cluster is rebuilt.

- `clusterName: platform`. The chart will not render without it, and the
  controller uses it to find and tag AWS resources.
- `region` and `vpcId`. The chart can discover both from EC2 IMDS, but the node
  launch template's IMDS hop limit blocks pods from reaching `169.254.169.254`.
  Without them the controller crashloops with `failed to introspect vpcID`. Get
  the VPC ID with:

  ```bash
  aws eks describe-cluster --name platform --region il-central-1 \
    --query cluster.resourcesVpcConfig.vpcId
  ```

**Behavior to know about.**

- `defaultTargetType: ip` registers pod IPs as targets through the VPC CNI
  instead of going through a NodePort on each node. It saves a hop and is
  required for pod readiness gates.
- The Service mutator webhook is on (chart default). **It is cluster-wide and
  fails closed on Service creation**: `failurePolicy: Fail`, no namespace
  selector, `rules: services/CREATE`. If the controller is down, nobody can
  create a Service anywhere in the cluster. The webhook is what sends an
  unannotated `type: LoadBalancer` Service to an NLB instead of a Classic ELB.
  Set `enableServiceMutatorWebhook: false` to drop it and annotate those
  Services yourself.
- All `alb` Ingresses share one ALB. `ingressClassParams.spec.group.name: shared`
  is set on the class, so every Ingress with `ingressClassName: alb` joins the
  same IngressGroup and cannot pick another one. This avoids paying for one ALB
  per app. Each app needs a unique host, settings such as `scheme` and listen
  ports must match across the group, and one broken Ingress blocks updates to
  the whole ALB (controller log: `failed to build LoadBalancer configuration`).

  ```bash
  kubectl get ingressclassparams alb -o jsonpath='{.spec.group.name}'   # shared
  kubectl get ingress -A                       # same ADDRESS for every alb Ingress
  ```

**AWS setup outside this repo.** AWS access uses EKS Pod Identity, which is IAM
and so not managed here. Before the controller can create load balancers you
need:

1. The EKS Pod Identity Agent addon on the cluster.
2. A Pod Identity association that binds an IAM role with
   `AWSLoadBalancerControllerIAMPolicy` to namespace
   `aws-load-balancer-controller`, ServiceAccount
   `aws-load-balancer-controller`. The ServiceAccount name is pinned in
   `values.yaml` so a chart rename cannot break the association.
3. Subnet discovery tags: `kubernetes.io/role/elb` on public subnets and
   `kubernetes.io/role/internal-elb` on private ones.

Without the association, the controller runs but logs AWS permission errors and
creates nothing.

## sample-app

A Node.js demo app. Its Helm chart lives in the app repo
(`sample-nodejs/chart/`) so code and chart change in the same PR. This repo
holds only the deployed values, including `image.tag`.

- `bootstrap/apps/sample-app.yaml` has two sources: the chart, and this repo
  with `ref: values`, which supplies `$values/workloads/apps/sample-app/values.yaml`.
- Project `sample-app` allows only those two repos and namespace `sample-app`.
  Anything else fails the sync with
  `namespace <ns> is not permitted in project 'sample-app'`.
- Argo CD creates the namespace with
  `pod-security.kubernetes.io/enforce: restricted`, so pods that don't meet the
  restricted profile are rejected.
- It is served at `https://sample-app.asafr.dev` on the shared ALB, on the
  public paths `/my-app` and `/about`. The ACM certificate is matched by host,
  and the ALB health-checks `/ready`.
- CI in `sample-nodejs` builds the image, pushes it to ECR and commits the new
  `image.tag` here. That commit is the deploy, and `git revert` is the rollback.

```bash
kubectl -n argocd get application sample-app      # Synced / Healthy
kubectl -n sample-app get pods,svc,ingress
curl https://sample-app.asafr.dev/my-app          # Hello, World!
```

## Testing the GitOps loop

Drift correction, no commit needed:

```bash
kubectl -n kubernetes-dashboard scale deploy/kubernetes-dashboard --replicas=0
# selfHeal sets it back to 1 within ~3 min
```

Change through Git: edit anything under `workloads/platform/kubernetes-dashboard/`
and push. Argo CD applies it on the next poll (~3 min) or on a manual refresh.

## Adding platform tooling

1. Create `workloads/platform/<name>/`.
2. Add either a `kustomization.yaml` or a `Chart.yaml` + `values.yaml` wrapping
   an upstream chart (like `external-secrets/`).
3. Commit and push.

The ApplicationSet creates an Application named after the folder. The
namespace is the folder name with any `-config` suffix removed:

| folder | Application | namespace |
|---|---|---|
| `external-dns/` | `external-dns` | `external-dns` |
| `myapp-config/` | `myapp-config` | `myapp` |

This lets a config folder deploy into its app's namespace, so `myapp-config/`
and `myapp/` would both use `myapp`. The project allows any namespace.

Cluster-scoped kinds need a project edit. The project currently allows
`Namespace`, `ClusterRole`, `ClusterRoleBinding`, `CustomResourceDefinition`,
`ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`,
`ClusterSecretStore`, `IngressClass` and `IngressClassParams`. For anything
else, add it to `clusterResourceWhitelist` in `bootstrap/projects/platform.yaml`,
or the sync fails with `resource <Kind> is not permitted in project platform`.

## Adding an application

Copy the sample-app pattern. The chart stays in the app's repo, and this repo
gets three files:

1. `bootstrap/projects/<name>.yaml`: an AppProject that allows the app repo,
   this repo and namespace `<name>` only.
2. `workloads/apps/<name>/values.yaml`: environment values. Use
   `ingressClassName: alb` with a unique host to join the shared ALB.
3. `bootstrap/apps/<name>.yaml`: a two-source Application like
   `sample-app.yaml`, in project `<name>`, sync-wave `1`.

Root syncs `bootstrap/` recursively, so committing these is enough. Once there
are several apps, an ApplicationSet over `workloads/apps/*` could replace the
copied Application files.

## Caveat: Argo CD itself is installed by Helm

Argo CD was installed with the `argo-cd` Helm chart v10.4.2 (appVersion v3.5.2),
release `argo-cd`, and this repo does not manage that install.
`workloads/platform/argocd/` sets only two keys:

| ConfigMap        | Key                                  | Value           |
|------------------|--------------------------------------|-----------------|
| `argocd-cm`      | `application.resourceTrackingMethod` | `annotation`    |
| `argocd-rbac-cm` | `policy.default`                     | `role:readonly` |

With server-side apply, Git owns only those two fields and Helm owns the rest.
A later `helm upgrade` may report a field-manager conflict on them. Fix it by
setting the same values in the chart's `configs.cm` / `configs.rbac`, or delete
these two files if Argo CD moves fully under Helm.

## Out of scope

SSO/OIDC, multiple environments, Argo CD Notifications, Image Updater and
network policies.
