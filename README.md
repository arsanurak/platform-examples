# platform-examples

[![PR checks](https://github.com/arsanurak/platform-examples/actions/workflows/pr.yml/badge.svg?branch=main)](https://github.com/arsanurak/platform-examples/actions/workflows/pr.yml)

## What this is

Example configuration for an EKS platform, written in one house style: how the Terraform and the GitOps files are laid out, named and checked. Nothing here is meant to be applied or run against a cluster. Every value that would identify a real system is a placeholder: account `000000000000`, domain `stage.example.com`, business domains `orders` and `billing`. CI proves the config statically, with no credentials. [ADR 3](docs/adr/0003-example-config-not-a-runnable-demo.md) explains why this repo stopped being a runnable demo.

It goes with three case studies:

- [Platform migration in waves](https://arsanurak.github.io/case-studies/platform-migration-in-waves/): the GitOps layout under `gitops/`.
- [CI pipeline guardrails](https://arsanurak.github.io/case-studies/ci-pipeline-guardrails/): the IAM components under `iac/stage/iam/` and their tests.
- [Agent-assisted delivery](https://arsanurak.github.io/case-studies/agent-assisted-delivery/): the issues, PRs, ADRs and agent hooks that built this repo.

## Map

### `iac/stage/`: one Terraform root, one file per concern

| File | What it holds |
| --- | --- |
| `versions.tf` | Terraform and provider versions, pinned. |
| `provider.tf` | The AWS provider, locked to the placeholder account, and the Helm provider pointed at the cluster. |
| `backend.tf` | Where state would live: a placeholder S3 bucket. |
| `variables.tf`, `outputs.tf` | Inputs with placeholder defaults; what other roots would read. |
| `kms.tf` | One rotating key for cluster secrets, log groups, databases and buckets. |
| `vpc.tf` | Private and public subnets per zone, one NAT gateway, flow logs, a closed default security group. |
| `eks.tf` | The control plane: private endpoint, encrypted secrets, every log type kept a year, admin through an access entry. |
| `node-group.tf` | A small managed node group for system pods, IMDSv2 only, encrypted disks. |
| `eks-addons.tf` | VPC CNI, CoreDNS, kube-proxy, the Pod Identity agent and External Secrets. |
| `ebs-csi.tf` | The EBS CSI driver add-on and its Pod Identity role. |
| `karpenter.tf` | Karpenter's controller role, its node role, the interruption queue and the chart. |
| `lbc.tf` | The AWS Load Balancer Controller's role and chart. |
| `dns.tf` | The public zone `stage.example.com`. |
| `acm.tf` | The wildcard certificate `*.stage.example.com`, validated through DNS. |
| `rds.tf` | One private, encrypted, multi-AZ Postgres per business domain. |
| `s3.tf` | One versioned, encrypted, private bucket per business domain. |
| `waf.tf` | The regional web ACL the public Ingresses use; rule data in `waf/`. |
| `argocd.tf` | Argo CD and one root app that syncs `gitops/platform/`. |
| `iam.tf` | The CI identity: GitHub OIDC, the Execution role, its Permission boundary and Guardrail policy, the payment-lockout SCP. A human admin applies these. |
| `iam/<component>/` | One folder per IAM role or policy: its JSON and its pytest tests. |
| `waf/` | WAF rule data: the managed rule groups and the rate limit. |
| `tests/` | `terraform test` files, run against mock providers. |

The IAM components: `execution-role`, `permission-boundary` (with the guardrail), `org-scp`, `karpenter-controller`, `lbc-controller`, `ebs-csi-driver` and `external-secrets`. Roles that only attach AWS managed policies (the cluster, node and flow-log roles) keep their short trust policy inline in their concern's file.

### `gitops/`: one folder per service

| Path | What it holds |
| --- | --- |
| `platform/` | Cluster-wide setup: one namespace per domain, the Karpenter NodePool and EC2NodeClass, the secret store, the Argo CD AppProject and the ApplicationSet. |
| `<domain>/<service>/` | One service, one file per kind: `orders` and `billing`, each with `api`, `web` and `admin`. |

[`gitops/README.md`](gitops/README.md) describes each file in `platform/`.

## Conventions

- **One file per concern.** A Terraform root is flat: each concern has one `.tf` file named after it. Read `rds.tf` to see everything about the databases.
- **Domain, service, kind.** A manifest lives at `gitops/<domain>/<service>/<domain>-<service>-<kind>.yaml`, and the object in it is named `<domain>-<service>` in namespace `<domain>`. Kinds: `deployment`, `svc`, `ingress`, `hpa`, `configmap`, `externalsecret`.
- **Policies are JSON files, tested.** Every custom IAM policy is a literal JSON file in `iam/<component>/`, exactly as attached, with pytest tests that ask an IAM evaluator what it allows and denies. Every workload role carries the Permission boundary.
- **Secrets stay out of git.** Credentials live in AWS Secrets Manager under `stage/<domain>/<service>`. Each service's ExternalSecret names its key; nothing else about the secret is in git. RDS generates and stores its own master password.
- **Controllers get permissions through EKS Pod Identity**, never from the node's role.
- **Adding a service** is copying a service folder, renaming it, and replacing the old `<domain>-<service>` names inside it. The ApplicationSet picks it up.
- **Adding an environment** (say `prod`): copy `iac/stage/` to `iac/prod/`, change the `environment` variable (its validation pins it, because the IAM JSON names `stage` resources literally), the `stage` names in its IAM JSON, and its state key. Leave out `iam.tf` and the `execution-role/`, `permission-boundary/` and `org-scp/` JSON it reads: the CI identity, GitHub OIDC provider and SCP are account-level, with fixed `platform-*` names, so a second copy in the same account would clash. The new root reuses the existing `platform-boundary` ARN (for example through a `data "aws_iam_policy"` lookup) wherever `iac/stage` uses `aws_iam_policy.boundary.arn`. Point the new cluster's root app at the same `gitops/` tree, with per-environment values in an overlay. Today there is one environment, so there are no overlays.

## Checks

```sh
make check
```

Runs every check the [PR workflow](.github/workflows/pr.yml) runs, with no cloud credentials and no cluster:

- `make test-iac`: `terraform fmt`, `validate`, and `terraform test` with mocked providers; tflint, trivy and checkov; the IAM policy tests in `iac/stage/iam/`.
- `make check-gitops`: kubeconform on every manifest, with pinned Kubernetes, Argo CD, Karpenter and External Secrets schemas. It also checks that each known-bad file in `tests/fixtures/gitops-invalid/` is rejected.
- `make test-hooks` and `make check-actions`: the agent hook tests, and a check that every GitHub Action is pinned to a commit SHA.

The first run of `make iac-tools` downloads the pinned tools (tflint, trivy, kubeconform, checkov, pytest) into `.tools/` and verifies their checksums. You need Terraform 1.11 or later and Python 3. `make help` lists every target.

Scanner checks that don't fit example config are skipped inline, each with its reason next to it.

## How this repo was built

An agent (Claude Code) wrote most of this repo, one ticket and one pull request at a time, with a human reviewing each PR. [Issue #1](https://github.com/arsanurak/platform-examples/issues/1) is the map of the first build. [Issue #18](https://github.com/arsanurak/platform-examples/issues/18) turned the demo into example config. The decisions are recorded as ADRs in [`docs/adr/`](docs/adr/).

[`CLAUDE.md`](CLAUDE.md) holds the agent's rules for this public repo, and [`CONTEXT.md`](CONTEXT.md) the shared vocabulary. [`.claude/settings.json`](.claude/settings.json) runs two hooks before the agent's tool calls:

- [`secret_guard.py`](.claude/hooks/secret_guard.py) blocks secret-shaped values in writes and commands, and reads of well-known secret files.
- [`command_guard.py`](.claude/hooks/command_guard.py) blocks cluster and cloud writes, destructive commands and data exfiltration.

Their tests are in `tests/hooks/`. They call each hook the way Claude Code does and check that it blocks or allows the call.

## Left out on purpose

- **A real apply.** It needs an account and costs money. The providers only accept the placeholder account.
- **DNS records for the load balancers.** In practice external-dns writes them. Here the zone and the certificate show the shape.
- **Monitoring and logging stacks.** They are out of scope for a layout example.
- **More than one environment.** The section above describes how a second one would be added.
