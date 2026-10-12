"""The Execution role CI assumes: who can assume it and what it can do.

Its identity policies are policy.json and the Guardrail policy; the
Permission boundary caps both.
"""

import pytest

from conftest import ACCOUNT, ALLOWED, EXPLICIT_DENY, IMPLICIT_DENY, REGION, evaluate

ROLE = f"arn:aws:iam::{ACCOUNT}:role/platform-execution"
BOUNDARY = f"arn:aws:iam::{ACCOUNT}:policy/platform-boundary"
GUARDRAIL = f"arn:aws:iam::{ACCOUNT}:policy/platform-guardrail"
WORKLOAD_ROLE = f"arn:aws:iam::{ACCOUNT}:role/workload/stage-karpenter-controller"
IN_REGION = {"aws:RequestedRegion": REGION}

# Written out here, not read from the JSON, so the test is an independent spec.
ROLE_EDIT_ACTIONS = [
    "iam:AttachRolePolicy",
    "iam:DeleteRolePermissionsBoundary",
    "iam:DeleteRolePolicy",
    "iam:DetachRolePolicy",
    "iam:PutRolePermissionsBoundary",
    "iam:PutRolePolicy",
    "iam:UpdateAssumeRolePolicy",
]
POLICY_EDIT_ACTIONS = ["iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]


@pytest.fixture
def execution(policy, decide_bounded):
    """Decide a call made by the Execution role."""
    identity = [policy("execution-role"), policy("permission-boundary", "guardrail.json")]
    boundary = policy("permission-boundary")

    def run(action, resource="*", context=None):
        return decide_bounded(identity, boundary, action, resource, context)

    return run


def github_token(sub, aud="sts.amazonaws.com"):
    return {"token.actions.githubusercontent.com:aud": aud, "token.actions.githubusercontent.com:sub": sub}


def test_only_main_of_the_example_repository_can_assume_it(policy):
    trust = [policy("execution-role", "trust.json")]
    main = github_token("repo:example-org/platform-examples:ref:refs/heads/main")
    assert evaluate(trust, "sts:AssumeRoleWithWebIdentity", ROLE, main) == ALLOWED
    for sub in [
        "repo:example-org/platform-examples:ref:refs/heads/feature",
        "repo:example-org/platform-examples:pull_request",
        "repo:example-org/other:ref:refs/heads/main",
    ]:
        assert evaluate(trust, "sts:AssumeRoleWithWebIdentity", ROLE, github_token(sub)) == IMPLICIT_DENY, sub


def test_the_token_must_be_issued_for_sts(policy):
    trust = [policy("execution-role", "trust.json")]
    token = github_token("repo:example-org/platform-examples:ref:refs/heads/main", aud="example.com")
    assert evaluate(trust, "sts:AssumeRoleWithWebIdentity", ROLE, token) == IMPLICIT_DENY


def test_it_cannot_be_assumed_with_a_plain_assume_role(policy):
    assert evaluate([policy("execution-role", "trust.json")], "sts:AssumeRole", ROLE) == IMPLICIT_DENY


@pytest.mark.parametrize("action", ROLE_EDIT_ACTIONS)
def test_it_cannot_edit_itself(execution, action):
    assert execution(action, ROLE) == EXPLICIT_DENY


@pytest.mark.parametrize("action", POLICY_EDIT_ACTIONS)
@pytest.mark.parametrize("target", [BOUNDARY, GUARDRAIL, f"arn:aws:iam::{ACCOUNT}:policy/platform-execution"])
def test_it_cannot_rewrite_its_own_policies(execution, action, target):
    assert execution(action, target) == EXPLICIT_DENY


def test_it_creates_workload_roles_only_with_the_boundary(execution):
    assert execution("iam:CreateRole", WORKLOAD_ROLE, {"iam:PermissionsBoundary": BOUNDARY}) == ALLOWED
    assert execution("iam:CreateRole", WORKLOAD_ROLE) == IMPLICIT_DENY
    other = f"arn:aws:iam::{ACCOUNT}:policy/something-looser"
    assert execution("iam:CreateRole", WORKLOAD_ROLE, {"iam:PermissionsBoundary": other}) == IMPLICIT_DENY


def test_it_creates_roles_only_under_the_workload_path(execution):
    admin = f"arn:aws:iam::{ACCOUNT}:role/platform-admin"
    assert execution("iam:CreateRole", admin, {"iam:PermissionsBoundary": BOUNDARY}) == IMPLICIT_DENY


def test_it_cannot_strip_the_boundary_from_a_workload_role(execution):
    assert execution("iam:DeleteRolePermissionsBoundary", WORKLOAD_ROLE) == EXPLICIT_DENY


def test_it_passes_workload_roles_only_to_the_services_that_use_them(execution):
    for service in ["eks.amazonaws.com", "ec2.amazonaws.com", "pods.eks.amazonaws.com"]:
        assert execution("iam:PassRole", WORKLOAD_ROLE, {"iam:PassedToService": service}) == ALLOWED, service
    assert execution("iam:PassRole", WORKLOAD_ROLE, {"iam:PassedToService": "lambda.amazonaws.com"}) == IMPLICIT_DENY
    assert execution("iam:PassRole", ROLE, {"iam:PassedToService": "ec2.amazonaws.com"}) == IMPLICIT_DENY


def test_it_cannot_create_users_or_access_keys(execution):
    assert execution("iam:CreateUser", f"arn:aws:iam::{ACCOUNT}:user/someone") == IMPLICIT_DENY
    assert execution("iam:CreateAccessKey", f"arn:aws:iam::{ACCOUNT}:user/someone") == IMPLICIT_DENY


def test_it_cannot_create_managed_policies(execution):
    """Controller policies are inline on their roles, so CI never needs iam:CreatePolicy."""
    assert execution("iam:CreatePolicy", f"arn:aws:iam::{ACCOUNT}:policy/anything") == IMPLICIT_DENY


@pytest.mark.parametrize(
    "action",
    [
        "ec2:CreateVpc",
        "eks:CreateCluster",
        "eks:CreatePodIdentityAssociation",
        "rds:CreateDBInstance",
        "s3:CreateBucket",
        "wafv2:CreateWebACL",
        "acm:RequestCertificate",
        "kms:CreateKey",
        "sqs:CreateQueue",
        "events:PutRule",
    ],
)
def test_it_builds_the_stage_infrastructure_in_one_region(execution, action):
    assert execution(action, "*", IN_REGION) == ALLOWED
    assert execution(action, "*", {"aws:RequestedRegion": "us-east-1"}) == IMPLICIT_DENY


def test_it_manages_dns(execution):
    assert execution("route53:CreateHostedZone") == ALLOWED
