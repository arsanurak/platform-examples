"""The AWS Load Balancer Controller's role: it manages only the load balancers it tags."""

import pytest

from conftest import ACCOUNT, ALLOWED, IMPLICIT_DENY, REGION, evaluate

ELB = f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}"
ALB = f"{ELB}:loadbalancer/app/k8s-stagepublic/0"
SG = f"arn:aws:ec2:{REGION}:{ACCOUNT}:security-group/sg-0"
REQUEST_TAGGED = {"aws:RequestTag/elbv2.k8s.aws/cluster": "stage"}
TAGGED = {"aws:ResourceTag/elbv2.k8s.aws/cluster": "stage"}


@pytest.fixture
def lbc(policy):
    def run(action, resource="*", context=None):
        return evaluate([policy("lbc-controller")], action, resource, dict(context or {}, **{"aws:RequestedRegion": REGION}))

    return run


def test_it_creates_load_balancers_only_with_its_cluster_tag(lbc):
    assert lbc("elasticloadbalancing:CreateLoadBalancer", ALB, REQUEST_TAGGED) == ALLOWED
    assert lbc("elasticloadbalancing:CreateLoadBalancer", ALB) == IMPLICIT_DENY


def test_it_changes_and_deletes_only_load_balancers_it_tagged(lbc):
    for action in ["elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyLoadBalancerAttributes"]:
        assert lbc(action, ALB, TAGGED) == ALLOWED, action
        assert lbc(action, ALB) == IMPLICIT_DENY, action


def test_it_deletes_only_security_groups_it_tagged(lbc):
    assert lbc("ec2:DeleteSecurityGroup", SG, TAGGED) == ALLOWED
    assert lbc("ec2:DeleteSecurityGroup", SG) == IMPLICIT_DENY


def test_it_attaches_the_waf_acl_and_reads_certificates(lbc):
    assert lbc("wafv2:AssociateWebACL", "*") == ALLOWED
    assert lbc("acm:DescribeCertificate", "*") == ALLOWED
    assert lbc("acm:RequestCertificate", "*") == IMPLICIT_DENY


def test_its_only_iam_write_is_the_load_balancing_service_linked_role(lbc):
    slr = f"arn:aws:iam::{ACCOUNT}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
    for_elb = {"iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"}
    assert lbc("iam:CreateServiceLinkedRole", slr, for_elb) == ALLOWED
    assert lbc("iam:CreateServiceLinkedRole", slr) == IMPLICIT_DENY
    assert lbc("iam:CreateRole", f"arn:aws:iam::{ACCOUNT}:role/workload/anything") == IMPLICIT_DENY


def test_only_pods_in_the_stage_cluster_can_assume_it(policy):
    trust = [policy("lbc-controller", "trust.json")]
    stage = {"aws:SourceAccount": ACCOUNT, "aws:SourceArn": f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/stage"}
    assert evaluate(trust, "sts:AssumeRole", "*", stage) == ALLOWED
    assert evaluate(trust, "sts:AssumeRole", "*", {"aws:SourceAccount": ACCOUNT}) == IMPLICIT_DENY


def test_it_creates_security_groups_only_with_its_cluster_tag(lbc):
    vpc = f"arn:aws:ec2:{REGION}:{ACCOUNT}:vpc/vpc-0"
    assert lbc("ec2:CreateSecurityGroup", SG, REQUEST_TAGGED) == ALLOWED
    assert lbc("ec2:CreateSecurityGroup", SG) == IMPLICIT_DENY
    # The VPC half of the call carries no request tags, as upstream allows.
    assert lbc("ec2:CreateSecurityGroup", vpc) == ALLOWED
