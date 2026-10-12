# The identity CI applies this root with: GitHub's OIDC provider, the
# Execution role, its Permission boundary and Guardrail policy, and the
# organization SCP. A human admin applies these resources; the Guardrail
# policy stops CI changing them afterwards. Every document is the literal
# JSON under iam/, which the pytest suite there tests.

# GitHub's OIDC issuer. CI exchanges a short-lived GitHub token for role
# credentials, so no access key for the Execution role ever exists.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# The Permission boundary: the most CI or any workload role can ever do.
# trivy flags any iam:PassRole (AWS-0342). EKS, EC2 and Pod Identity need it
# to hand workload roles to their services; it is limited to role/workload/*
# and to those services by condition, and the pytest suite forbids it on "*".
#trivy:ignore:AWS-0342
resource "aws_iam_policy" "boundary" {
  name        = "platform-boundary"
  description = "Caps CI and every workload role, whatever their own policies grant."
  policy      = file("${path.module}/iam/permission-boundary/policy.json")
}

# Denies that stop the Execution role loosening itself. They are repeated
# inside the boundary, so detaching this policy would not lift them.
resource "aws_iam_policy" "guardrail" {
  name        = "platform-guardrail"
  description = "Denies the Execution role editing itself, its boundary or these policies."
  policy      = file("${path.module}/iam/permission-boundary/guardrail.json")
}

# PassRole: see the note on the boundary above.
#trivy:ignore:AWS-0342
resource "aws_iam_policy" "execution" {
  name        = "platform-execution"
  description = "What the Execution role needs to apply this root."
  policy      = file("${path.module}/iam/execution-role/policy.json")
}

resource "aws_iam_role" "execution" {
  name                 = "platform-execution"
  description          = "Assumed by CI through GitHub OIDC to apply infrastructure."
  assume_role_policy   = file("${path.module}/iam/execution-role/trust.json")
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "execution" {
  for_each = {
    guardrail   = aws_iam_policy.guardrail.arn
    permissions = aws_iam_policy.execution.arn
  }

  role       = aws_iam_role.execution.name
  policy_arn = each.value
}

# Account-level protection beyond IAM: an organization SCP that stops every
# principal in the target accounts changing how the bill is paid.
resource "aws_organizations_policy" "payment_lockout" {
  name        = "deny-payment-method-changes"
  description = "No principal in a member account can change how the bill is paid."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/iam/org-scp/policy.json")
}

resource "aws_organizations_policy_attachment" "payment_lockout" {
  policy_id = aws_organizations_policy.payment_lockout.id
  target_id = var.scp_target_id
}
