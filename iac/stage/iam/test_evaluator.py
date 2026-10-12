"""The evaluator in conftest.py, checked against worked IAM examples.

Every other test here trusts its answers, so it gets its own small spec.
"""

from conftest import ALLOWED, EXPLICIT_DENY, IMPLICIT_DENY, evaluate, evaluate_bounded


def doc(*statements):
    return {"Version": "2012-10-17", "Statement": list(statements)}


ALLOW_S3_READ = {"Effect": "Allow", "Action": "s3:Get*", "Resource": "arn:aws:s3:::bucket/*"}


def test_nothing_granted_is_an_implicit_deny():
    assert evaluate([doc()], "s3:GetObject", "arn:aws:s3:::bucket/key") == IMPLICIT_DENY


def test_a_wildcard_action_allows_and_actions_ignore_case():
    assert evaluate([doc(ALLOW_S3_READ)], "S3:getobject", "arn:aws:s3:::bucket/key") == ALLOWED


def test_resource_arns_are_case_sensitive():
    assert evaluate([doc(ALLOW_S3_READ)], "s3:GetObject", "arn:aws:s3:::Bucket/key") == IMPLICIT_DENY


def test_a_deny_anywhere_beats_any_allow():
    deny = {"Effect": "Deny", "Action": "s3:*", "Resource": "*"}
    assert evaluate([doc(ALLOW_S3_READ), doc(deny)], "s3:GetObject", "arn:aws:s3:::bucket/key") == EXPLICIT_DENY


def test_not_action_allows_everything_it_does_not_name():
    statement = {"Effect": "Allow", "NotAction": "iam:*", "Resource": "*"}
    assert evaluate([doc(statement)], "ec2:RunInstances") == ALLOWED
    assert evaluate([doc(statement)], "iam:CreateRole") == IMPLICIT_DENY


def test_string_equals_needs_the_key_in_the_request():
    statement = {
        "Effect": "Allow",
        "Action": "ec2:*",
        "Resource": "*",
        "Condition": {"StringEquals": {"aws:RequestedRegion": "eu-west-1"}},
    }
    assert evaluate([doc(statement)], "ec2:RunInstances", context={"aws:RequestedRegion": "eu-west-1"}) == ALLOWED
    assert evaluate([doc(statement)], "ec2:RunInstances", context={"aws:RequestedRegion": "us-east-1"}) == IMPLICIT_DENY
    assert evaluate([doc(statement)], "ec2:RunInstances") == IMPLICIT_DENY


def test_string_like_and_null_conditions():
    statement = {
        "Effect": "Allow",
        "Action": "ec2:TerminateInstances",
        "Resource": "*",
        "Condition": {
            "StringLike": {"aws:ResourceTag/karpenter.sh/nodepool": "*"},
            "Null": {"aws:ResourceTag/owner": "true"},
        },
    }
    tagged = {"aws:ResourceTag/karpenter.sh/nodepool": "default"}
    assert evaluate([doc(statement)], "ec2:TerminateInstances", context=tagged) == ALLOWED
    assert evaluate([doc(statement)], "ec2:TerminateInstances") == IMPLICIT_DENY
    owned = dict(tagged, **{"aws:ResourceTag/owner": "someone"})
    assert evaluate([doc(statement)], "ec2:TerminateInstances", context=owned) == IMPLICIT_DENY


def test_a_bool_condition_reads_true_and_false():
    statement = {
        "Effect": "Deny",
        "Action": "s3:*",
        "Resource": "*",
        "Condition": {"Bool": {"aws:SecureTransport": "false"}},
    }
    assert evaluate([doc(statement)], "s3:GetObject", context={"aws:SecureTransport": "false"}) == EXPLICIT_DENY
    assert evaluate([doc(statement)], "s3:GetObject", context={"aws:SecureTransport": "true"}) == IMPLICIT_DENY


def test_a_boundary_caps_what_identity_policies_grant():
    identity = [doc({"Effect": "Allow", "Action": "*", "Resource": "*"})]
    boundary = doc({"Effect": "Allow", "Action": "ec2:*", "Resource": "*"})
    assert evaluate_bounded(identity, boundary, "ec2:RunInstances") == ALLOWED
    assert evaluate_bounded(identity, boundary, "iam:CreateUser") == IMPLICIT_DENY


def test_for_all_values_needs_every_requested_value_listed():
    statement = {
        "Effect": "Allow",
        "Action": "ec2:CreateTags",
        "Resource": "*",
        "Condition": {"ForAllValues:StringEquals": {"aws:TagKeys": ["Name", "team"]}},
    }
    assert evaluate([doc(statement)], "ec2:CreateTags", context={"aws:TagKeys": ["Name"]}) == ALLOWED
    assert evaluate([doc(statement)], "ec2:CreateTags", context={"aws:TagKeys": ["Name", "owner"]}) == IMPLICIT_DENY
