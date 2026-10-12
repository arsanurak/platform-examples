# 3. Example config, not a runnable demo

Date: 2026-10-12

## Status

Accepted. Supersedes [ADR 2](0002-cutover-changes-old-at-runtime.md).

## Context

This repo started as a runnable demo: two local kind clusters, Argo CD on each, six sample apps moved between them in waves, with parity, cutover and rollback scripts. Running it needed Docker with about 8 GB of memory, and most of the code existed to make the laptop tour work rather than to show how platform code is written.

What a reader actually wants from it is the house style: how infrastructure code and GitOps files are laid out, named and checked. The tour hid that behind tooling nobody would copy.

## Decision

The repo becomes example configuration. Nothing in it is meant to be applied or run against a cluster.

- `iac/stage/` is one Terraform root with one file per concern, placeholder values (account `000000000000`, `example.com`) and an `iam/<component>/` folder per IAM role or policy, each with its JSON and its policy tests.
- `gitops/` is laid out as `<domain>/<service>/<domain>-<service>-<kind>.yaml`, plus `gitops/platform/` for what the cluster needs before any service (namespaces, Karpenter, the Argo CD project and ApplicationSet).
- CI proves it statically, with no credentials: `terraform fmt`, `validate` and `test` with mocked providers, tflint, trivy, checkov, the policy tests and kubeconform with CRD schemas.

The kind clusters, `make up`/`down`, the waves and their generator, parity, cutover, rollback and the smoke-test workflow are removed. ADR 2 described how a cutover changed the old cluster at runtime; with no cutover left, it no longer applies.

## Consequences

- No local runtime: `make check` needs Terraform, Python 3 and the pinned tools `make iac-tools` downloads.
- Nothing proves the config works on a real cluster. The static checks prove it is well formed, scanned and consistent; the case studies describe how the real work ran.
- The migration story is told by the case study, not by a tour in this repo.
- Adding a service is copying a folder; adding an environment is copying `iac/stage/` and the placeholders in it (see the README).
