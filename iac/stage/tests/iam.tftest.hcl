# Plan-level tests for the CI identity and the workload roles. The pytest
# suite in iam/ covers what is inside each policy document; these cover how
# this root wires the documents together.

mock_provider "aws" {
  override_during = plan
}

mock_provider "helm" {}

override_resource {
  override_during = plan
  target          = aws_iam_policy.boundary
  values          = { arn = "arn:aws:iam::000000000000:policy/platform-boundary" }
}

override_resource {
  override_during = plan
  target          = aws_iam_policy.guardrail
  values          = { arn = "arn:aws:iam::000000000000:policy/platform-guardrail" }
}

override_resource {
  override_during = plan
  target          = aws_iam_policy.execution
  values          = { arn = "arn:aws:iam::000000000000:policy/platform-execution" }
}

run "policy_names_match_the_arns_inside_the_json" {
  command = plan

  assert {
    condition = (
      aws_iam_policy.boundary.name == "platform-boundary" &&
      aws_iam_policy.guardrail.name == "platform-guardrail" &&
      aws_iam_policy.execution.name == "platform-execution" &&
      aws_iam_role.execution.name == "platform-execution"
    )
    error_message = "The policy JSON names these ARNs literally, so the names here must not drift."
  }
}

run "execution_role_is_capped_by_the_boundary" {
  command = plan

  assert {
    condition     = aws_iam_role.execution.permissions_boundary == "arn:aws:iam::000000000000:policy/platform-boundary"
    error_message = "The Execution role must carry the Permission boundary."
  }
}

run "guardrail_is_attached_to_the_execution_role" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.execution["guardrail"].policy_arn == "arn:aws:iam::000000000000:policy/platform-guardrail"
    error_message = "The Guardrail policy must be attached to the Execution role."
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy_attachment.execution)) == toset(["guardrail", "permissions"])
    error_message = "The Execution role must get exactly its own permissions and the Guardrail policy."
  }
}

run "only_main_of_one_repository_can_assume_the_role" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The role must only be assumable through web identity (OIDC)."
  }

  assert {
    condition = jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = "repo:example-org/platform-examples:ref:refs/heads/main"
    }
    error_message = "The trust must pin the audience and the exact repository and branch, with no wildcard."
  }
}

run "github_is_the_only_oidc_issuer" {
  command = plan

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com"
    error_message = "The OIDC provider must be GitHub Actions' token issuer."
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "Tokens must be issued for STS only."
  }
}

run "payment_lockout_is_an_attached_scp" {
  command = plan

  assert {
    condition     = aws_organizations_policy.payment_lockout.type == "SERVICE_CONTROL_POLICY"
    error_message = "The payment lockout must be a service control policy, so it binds whole accounts."
  }

  assert {
    condition     = jsondecode(aws_organizations_policy.payment_lockout.content).Statement[0].Effect == "Deny"
    error_message = "The payment lockout must deny."
  }

  assert {
    condition     = aws_organizations_policy_attachment.payment_lockout.target_id == var.scp_target_id
    error_message = "The payment lockout must be attached to its target."
  }
}

# The Execution role may only create roles under /workload/ that carry the
# Permission boundary, so every other role in this root must.
run "every_workload_role_is_bounded" {
  command = plan

  assert {
    condition = alltrue([
      for role in [
        aws_iam_role.cluster, aws_iam_role.node, aws_iam_role.flow_logs,
        aws_iam_role.karpenter_controller, aws_iam_role.karpenter_node,
        aws_iam_role.lbc_controller, aws_iam_role.ebs_csi_driver, aws_iam_role.external_secrets,
      ] :
      role.path == "/workload/" && role.permissions_boundary == aws_iam_policy.boundary.arn
    ])
    error_message = "Every workload role must sit under /workload/ and carry the Permission boundary."
  }
}

# Controller roles get their permissions as inline policies read from the
# JSON in iam/, so CI never needs iam:CreatePolicy.
run "controller_policies_are_the_json_in_iam" {
  command = plan

  assert {
    condition = alltrue([
      for pair in [
        [aws_iam_role_policy.karpenter_controller.policy, "karpenter-controller"],
        [aws_iam_role_policy.lbc_controller.policy, "lbc-controller"],
        [aws_iam_role_policy.ebs_csi_driver.policy, "ebs-csi-driver"],
        [aws_iam_role_policy.external_secrets.policy, "external-secrets"],
      ] :
      jsondecode(pair[0]) == jsondecode(file("iam/${pair[1]}/policy.json"))
    ])
    error_message = "Each controller's inline policy must be exactly its iam/<component>/policy.json."
  }
}
