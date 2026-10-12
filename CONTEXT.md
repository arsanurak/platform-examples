# platform-demo

Public example configuration in a house style: how Terraform and GitOps files for an EKS platform are laid out, named and checked. Nothing here is applied or run; CI proves it statically.

## Language

### Layout

**Environment**:
One deployment of the platform, with its own Terraform root under `iac/` and its own cluster. This repo has one, `stage`.
_Avoid_: stage (as a verb), tier

**Concern**:
One piece of infrastructure in a Terraform root (the VPC, the cluster, Karpenter, the WAF, ...). Each concern has exactly one `.tf` file, named after it.
_Avoid_: module, layer

**Component**:
One IAM role or policy, with a folder under `iac/stage/iam/` holding its JSON and its policy tests.

**Domain**:
A business area that owns services and gets its own namespace: `orders` and `billing`.
_Avoid_: team, tenant

**Service**:
One deployable inside a **Domain**: `api`, `web` or `admin`. Its manifests live in `gitops/<domain>/<service>/`, one file per kind, named `<domain>-<service>-<kind>.yaml`.
_Avoid_: app, microservice

### Guardrails

**Execution role**:
The cloud identity CI assumes through OIDC to apply infrastructure. It holds no stored keys.
_Avoid_: CI user, deploy user

**Permission boundary**:
The policy that caps what the **Execution role** and every workload role can ever do, whatever their own policies grant.

**Guardrail policy**:
A deny policy that holds even against the **Execution role**: it can't edit itself or its **Permission boundary**, and it can't touch payment methods.

### Repo areas

**IaC area**:
The `iac/` folder: Terraform roots and modules.

**GitOps area**:
The `gitops/` folder: the manifests Argo CD would sync, one folder per **Service** plus `gitops/platform/`.

**Make target**:
A `make` entry point (`make check`, `make test-iac`, `make check-gitops`, ...). It is the only interface: the README, CI and tests all go through it.
_Avoid_: script, task

### Agent workflow

**Hook**:
A script the coding agent's harness runs before a tool call. A hook can block the call. This repo commits two: the **Secret guard** and the **Command guard**.

**Secret guard**:
The **Hook** that blocks writing secret-shaped values (cloud keys, tokens, private keys) and reading well-known secret files.

**Command guard**:
The **Hook** that blocks shell commands that write to a cluster or cloud, destroy data, or send data out of the machine.

**Map**:
The parent issue that lists every ticket for a piece of work and how they block each other.

## Relationships

- A **Domain** holds one or more **Services**; each **Service** belongs to exactly one **Domain** and runs in its namespace.
- An **Environment** is one Terraform root made of **Concerns**; IAM **Components** sit in its `iam/` folder.
- The **Permission boundary** caps the **Execution role** and every workload role; **Guardrail policies** protect both.
