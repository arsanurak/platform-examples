"""The Permission boundary caps CI and every workload role, whatever they are granted.

The tests give a role "allow everything" as its identity policy and check
what the boundary still stops.
"""

import pytest

from conftest import ACCOUNT, ALLOWED, EXPLICIT_DENY, IMPLICIT_DENY, REGION, as_list

ADMIN = [{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}]
EXECUTION_ROLE = f"arn:aws:iam::{ACCOUNT}:role/platform-execution"


@pytest.fixture
def capped(policy, decide_bounded):
    """Decide a call for a role granted everything but carrying the boundary."""
    boundary = policy("permission-boundary")

    def run(action, resource="*", context=None):
        return decide_bounded(ADMIN, boundary, action, resource, context)

    return run


def test_the_boundary_repeats_every_guardrail_deny(policy):
    """Detaching the Guardrail policy would not lift its denies."""
    boundary = as_list(policy("permission-boundary")["Statement"])
    for statement in as_list(policy("permission-boundary", "guardrail.json")["Statement"]):
        assert statement in boundary, f"{statement['Sid']} is missing from the boundary"


def test_the_guardrail_only_denies(policy):
    for statement in as_list(policy("permission-boundary", "guardrail.json")["Statement"]):
        assert statement["Effect"] == "Deny"


def test_even_an_admin_cannot_edit_the_execution_role(capped):
    assert capped("iam:PutRolePolicy", EXECUTION_ROLE) == EXPLICIT_DENY
    assert capped("iam:UpdateAssumeRolePolicy", EXECUTION_ROLE) == EXPLICIT_DENY


def test_even_an_admin_stays_in_one_region(capped):
    assert capped("ec2:RunInstances", "*", {"aws:RequestedRegion": REGION}) == ALLOWED
    assert capped("ec2:RunInstances", "*", {"aws:RequestedRegion": "us-east-1"}) == IMPLICIT_DENY


@pytest.mark.parametrize(
    "action",
    ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreatePolicy", "organizations:LeaveOrganization", "sts:AssumeRole"],
)
def test_even_an_admin_cannot_reach_outside_the_cap(capped, action):
    assert capped(action, "*", {"aws:RequestedRegion": REGION}) == IMPLICIT_DENY
