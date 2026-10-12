# IaC area

One Terraform root, `stage/`, written as example configuration: it is read and checked, never applied. See `docs/adr/0001-one-repo-for-iac-and-gitops.md` for why this lives next to `gitops/`.

`stage/` has one `.tf` file per concern (`vpc.tf`, `eks.tf`, `karpenter.tf`, `waf.tf`, ...). `stage/iam/<component>/` holds each IAM policy as literal JSON with its pytest tests, `stage/waf/` the WAF rule data, and `stage/tests/` the `terraform test` files, which run against mock providers.

`make test-iac` runs every check here with no cloud credentials: fmt, validate, `terraform test`, tflint, trivy, checkov and the policy tests. `make iac-tools` installs the pinned tools into `.tools/` first.
