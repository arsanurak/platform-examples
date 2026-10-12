"""The EBS CSI driver's role: it creates and deletes only the volumes it tags."""

import pytest

from conftest import ACCOUNT, ALLOWED, IMPLICIT_DENY, REGION, evaluate

EC2 = f"arn:aws:ec2:{REGION}:{ACCOUNT}"
VOLUME = f"{EC2}:volume/vol-0"
CREATED_BY_DRIVER = {"aws:RequestTag/ebs.csi.aws.com/cluster": "true"}
OWNED_BY_DRIVER = {"aws:ResourceTag/ebs.csi.aws.com/cluster": "true"}


@pytest.fixture
def driver(policy):
    def run(action, resource="*", context=None):
        return evaluate([policy("ebs-csi-driver")], action, resource, dict(context or {}, **{"aws:RequestedRegion": REGION}))

    return run


def test_it_creates_volumes_only_with_its_tag(driver):
    assert driver("ec2:CreateVolume", VOLUME, CREATED_BY_DRIVER) == ALLOWED
    assert driver("ec2:CreateVolume", VOLUME) == IMPLICIT_DENY


def test_it_deletes_only_volumes_it_created(driver):
    assert driver("ec2:DeleteVolume", VOLUME, OWNED_BY_DRIVER) == ALLOWED
    assert driver("ec2:DeleteVolume", VOLUME) == IMPLICIT_DENY


def test_it_attaches_volumes_to_nodes(driver):
    assert driver("ec2:AttachVolume", VOLUME) == ALLOWED
    assert driver("ec2:AttachVolume", f"{EC2}:instance/i-0") == ALLOWED


def test_it_uses_the_kms_key_only_through_ec2(driver):
    key = f"arn:aws:kms:{REGION}:{ACCOUNT}:key/00000000-0000-0000-0000-000000000000"
    via_ec2 = {"kms:ViaService": f"ec2.{REGION}.amazonaws.com", "kms:GrantIsForAWSResource": "true"}
    assert driver("kms:CreateGrant", key, via_ec2) == ALLOWED
    assert driver("kms:CreateGrant", key) == IMPLICIT_DENY
    assert driver("kms:Decrypt", key, {"kms:ViaService": f"ec2.{REGION}.amazonaws.com"}) == ALLOWED
    assert driver("kms:Decrypt", key) == IMPLICIT_DENY


def test_only_pods_in_the_stage_cluster_can_assume_it(policy):
    trust = [policy("ebs-csi-driver", "trust.json")]
    stage = {"aws:SourceAccount": ACCOUNT, "aws:SourceArn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/stage"}
    assert evaluate(trust, "sts:TagSession", "*", stage) == ALLOWED
    assert evaluate(trust, "sts:AssumeRole", "*", dict(stage, **{"aws:SourceAccount": "111111111111"})) == IMPLICIT_DENY
