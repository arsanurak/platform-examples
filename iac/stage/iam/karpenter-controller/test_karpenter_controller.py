"""Karpenter's controller role: it launches and removes nodes for the stage cluster only."""

import pytest

from conftest import ACCOUNT, ALLOWED, CLUSTER, IMPLICIT_DENY, REGION, evaluate

EC2 = f"arn:aws:ec2:{REGION}:{ACCOUNT}"
NODE_ROLE = f"arn:aws:iam::{ACCOUNT}:role/workload/stage-karpenter-node"
QUEUE = f"arn:aws:sqs:{REGION}:{ACCOUNT}:stage-karpenter"
OWNED = {f"aws:ResourceTag/kubernetes.io/cluster/{CLUSTER}": "owned", "aws:ResourceTag/karpenter.sh/nodepool": "default"}
REQUEST_OWNED = {
    "aws:RequestTag/kubernetes.io/cluster/stage": "owned",
    "aws:RequestTag/eks:eks-cluster-name": CLUSTER,
    "aws:RequestTag/karpenter.sh/nodepool": "default",
}


@pytest.fixture
def karpenter(policy):
    def run(action, resource="*", context=None):
        return evaluate([policy("karpenter-controller")], action, resource, dict(context or {}, **{"aws:RequestedRegion": REGION}))

    return run


def test_only_pods_in_the_stage_cluster_can_assume_it(policy):
    trust = [policy("karpenter-controller", "trust.json")]
    role = f"arn:aws:iam::{ACCOUNT}:role/workload/stage-karpenter-controller"
    stage = {"aws:SourceAccount": ACCOUNT, "aws:SourceArn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{CLUSTER}"}
    other = dict(stage, **{"aws:SourceArn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/other"})
    for action in ["sts:AssumeRole", "sts:TagSession"]:
        assert evaluate(trust, action, role, stage) == ALLOWED
        assert evaluate(trust, action, role, other) == IMPLICIT_DENY


def test_it_launches_nodes_only_tagged_for_the_cluster(karpenter):
    assert karpenter("ec2:RunInstances", f"{EC2}:instance/*", REQUEST_OWNED) == ALLOWED
    assert karpenter("ec2:RunInstances", f"{EC2}:instance/*") == IMPLICIT_DENY


def test_it_terminates_only_its_own_nodes(karpenter):
    assert karpenter("ec2:TerminateInstances", f"{EC2}:instance/i-0", OWNED) == ALLOWED
    assert karpenter("ec2:TerminateInstances", f"{EC2}:instance/i-0") == IMPLICIT_DENY
    other_cluster = {"aws:ResourceTag/kubernetes.io/cluster/other": "owned", "aws:ResourceTag/karpenter.sh/nodepool": "default"}
    assert karpenter("ec2:TerminateInstances", f"{EC2}:instance/i-0", other_cluster) == IMPLICIT_DENY


def test_it_passes_only_the_node_role_and_only_to_ec2(karpenter):
    assert karpenter("iam:PassRole", NODE_ROLE, {"iam:PassedToService": "ec2.amazonaws.com"}) == ALLOWED
    assert karpenter("iam:PassRole", NODE_ROLE, {"iam:PassedToService": "lambda.amazonaws.com"}) == IMPLICIT_DENY
    controller = f"arn:aws:iam::{ACCOUNT}:role/workload/stage-karpenter-controller"
    assert karpenter("iam:PassRole", controller, {"iam:PassedToService": "ec2.amazonaws.com"}) == IMPLICIT_DENY


def test_it_reads_its_interruption_queue(karpenter):
    for action in ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueUrl"]:
        assert karpenter(action, QUEUE) == ALLOWED
    assert karpenter("sqs:ReceiveMessage", f"arn:aws:sqs:{REGION}:{ACCOUNT}:another-queue") == IMPLICIT_DENY


def test_it_manages_instance_profiles_only_for_the_cluster(karpenter):
    profile = f"arn:aws:iam::{ACCOUNT}:instance-profile/stage_123"
    profile_tags = {"topology.kubernetes.io/region": REGION, "karpenter.k8s.aws/ec2nodeclass": "default"}
    requested = dict(REQUEST_OWNED, **{f"aws:RequestTag/{k}": v for k, v in profile_tags.items()})
    existing = dict(OWNED, **{f"aws:ResourceTag/{k}": v for k, v in profile_tags.items()})
    assert karpenter("iam:CreateInstanceProfile", profile, requested) == ALLOWED
    assert karpenter("iam:CreateInstanceProfile", profile, REQUEST_OWNED) == IMPLICIT_DENY
    assert karpenter("iam:AddRoleToInstanceProfile", profile, existing) == ALLOWED
    assert karpenter("iam:DeleteInstanceProfile", profile) == IMPLICIT_DENY


def test_it_retags_its_nodes_only_with_the_tags_it_owns(karpenter):
    node = f"{EC2}:instance/i-0"
    assert karpenter("ec2:CreateTags", node, dict(OWNED, **{"aws:TagKeys": ["karpenter.sh/nodeclaim"]})) == ALLOWED
    assert karpenter("ec2:CreateTags", node, dict(OWNED, **{"aws:TagKeys": ["kubernetes.io/cluster/stage"]})) == IMPLICIT_DENY


def test_it_cannot_create_roles(karpenter):
    assert karpenter("iam:CreateRole", f"arn:aws:iam::{ACCOUNT}:role/workload/anything") == IMPLICIT_DENY
