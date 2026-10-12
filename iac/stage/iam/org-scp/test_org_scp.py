"""The organization SCP: no principal in a member account can change how the bill is paid."""

import pytest

from conftest import ALLOWED, EXPLICIT_DENY, evaluate

# Written out here, not read from the JSON, so the test is an independent spec.
PAYMENT_ACTIONS = [
    "aws-portal:ModifyPaymentMethods",
    "payments:CreatePaymentInstrument",
    "payments:DeletePaymentInstrument",
    "payments:MakePayment",
    "payments:UpdatePaymentPreferences",
]


@pytest.mark.parametrize("action", PAYMENT_ACTIONS)
def test_payment_changes_are_denied_for_everyone(policy, action):
    for principal in ["arn:aws:iam::000000000000:role/platform-admin", "arn:aws:iam::000000000000:root"]:
        context = {"aws:PrincipalArn": principal}
        assert evaluate([policy("org-scp")], action, "*", context) == EXPLICIT_DENY


def test_the_deny_has_no_condition_to_slip_through(policy):
    for statement in policy("org-scp")["Statement"]:
        assert "Condition" not in statement


def test_it_only_denies_so_it_grants_nothing(policy):
    """An SCP never grants; the account's own IAM still decides what is allowed."""
    for statement in policy("org-scp")["Statement"]:
        assert statement["Effect"] == "Deny"
    assert evaluate([policy("org-scp")], "ec2:RunInstances") != ALLOWED
