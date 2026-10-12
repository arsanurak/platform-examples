"""External Secrets' role: it reads stage secrets from Secrets Manager and nothing else."""

import pytest

from conftest import ACCOUNT, ALLOWED, IMPLICIT_DENY, REGION, evaluate

SECRETS = f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret"


@pytest.fixture
def eso(policy):
    def run(action, resource="*", context=None):
        return evaluate([policy("external-secrets")], action, resource, dict(context or {}, **{"aws:RequestedRegion": REGION}))

    return run


def test_it_reads_stage_secrets(eso):
    for action in ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]:
        assert eso(action, f"{SECRETS}:stage/orders/api-AbCdEf") == ALLOWED, action


def test_it_cannot_read_another_environments_secrets(eso):
    assert eso("secretsmanager:GetSecretValue", f"{SECRETS}:prod/orders/api-AbCdEf") == IMPLICIT_DENY


def test_it_cannot_write_secrets(eso):
    for action in ["secretsmanager:PutSecretValue", "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret"]:
        assert eso(action, f"{SECRETS}:stage/orders/api-AbCdEf") == IMPLICIT_DENY, action


def test_it_decrypts_only_through_secrets_manager(eso):
    key = f"arn:aws:kms:{REGION}:{ACCOUNT}:key/00000000-0000-0000-0000-000000000000"
    assert eso("kms:Decrypt", key, {"kms:ViaService": f"secretsmanager.{REGION}.amazonaws.com"}) == ALLOWED
    assert eso("kms:Decrypt", key) == IMPLICIT_DENY


def test_only_pods_in_the_stage_cluster_can_assume_it(policy):
    trust = [policy("external-secrets", "trust.json")]
    stage = {"aws:SourceAccount": ACCOUNT, "aws:SourceArn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/stage"}
    assert evaluate(trust, "sts:AssumeRole", "*", stage) == ALLOWED
    assert evaluate(trust, "sts:AssumeRoleWithWebIdentity", "*", stage) == IMPLICIT_DENY
