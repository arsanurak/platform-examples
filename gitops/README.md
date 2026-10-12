# GitOps area

What Argo CD syncs onto the `stage` cluster. Nothing here is applied by hand: `iac/stage/argocd.tf` installs Argo CD with one root app that points at `platform/`, and `platform/applicationset.yaml` turns every service folder into an app. See `docs/adr/0001-one-repo-for-iac-and-gitops.md` for why this lives next to `iac/`.

```
gitops/
  platform/                 cluster-wide setup, synced by the root app
  <domain>/<service>/       one folder per service, one app each
    <domain>-<service>-<kind>.yaml
```

## Layout

| Path | What it holds |
| --- | --- |
| `platform/<domain>-namespace.yaml` | One namespace per domain (`orders`, `billing`), restricted Pod Security. |
| `platform/karpenter-nodepool.yaml` | The NodePool service pods run on: spot or on-demand, recent c/m/r instances, a CPU and memory ceiling. |
| `platform/karpenter-ec2nodeclass.yaml` | How Karpenter builds a node: role `stage-karpenter-node`, subnets and security group found by the `karpenter.sh/discovery: stage` tag, IMDSv2 only, encrypted disk. |
| `platform/cluster-secret-store.yaml` | `aws-secrets-manager`: the one secret store, usable only from the domain namespaces. |
| `platform/appproject.yaml` | Project `services`: this repo only, the domain namespaces only, and only the six kinds a service folder holds. |
| `platform/applicationset.yaml` | A git directory generator over `gitops/*/*` (minus `platform/`): one app `<domain>-<service>` per folder, deployed into namespace `<domain>`. |
| `<domain>/<service>/` | One service: `orders` and `billing`, each with `api`, `web` and `admin`. |

## Conventions

- **Names.** A file is `<domain>-<service>-<kind>.yaml`, and every object in it is named `<domain>-<service>` in namespace `<domain>`. Kinds: `deployment`, `svc`, `ingress`, `hpa`, `configmap`, `externalsecret`.
- **Scaling.** A Deployment with an HPA has no `replicas` field, so Argo CD never fights the autoscaler. `admin` services have no HPA and a fixed replica count.
- **Ingress.** Class `alb`, served by the AWS Load Balancer Controller. Host `<domain>-<service>.stage.example.com`. `api` and `web` join the internet-facing group `stage-public`, behind the WAF web ACL; `admin` joins the internal group `stage-internal`. The controller finds the wildcard certificate from the TLS host, so no certificate ARN is in git.
- **Config and secrets.** Plain settings go in the ConfigMap. Credentials live in AWS Secrets Manager under `stage/<domain>/<service>`; the ExternalSecret copies them into a Secret of the service's name. Only the key's name is in git.
- **Workload.** podinfo stands in for every service, pinned by digest, non-root with a read-only root filesystem.

## Adding a service

Copy a service folder, rename the folder and files, and replace the old `<domain>-<service>` and `stage/<domain>/<service>` everywhere in it. The ApplicationSet picks it up; nothing else changes. A new domain also needs `platform/<domain>-namespace.yaml` and the namespace added to `appproject.yaml` and `cluster-secret-store.yaml`.

## Checks

`make check-gitops` validates every manifest here with kubeconform, against pinned Kubernetes schemas and pinned Argo CD, Karpenter and External Secrets CRD schemas. A kind with no schema fails the check. It also runs kubeconform on the known-bad files in `tests/fixtures/gitops-invalid/` and fails unless each one is rejected.
