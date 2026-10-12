"""Properties every policy JSON under iac/stage/iam must have."""

import json
import re

import pytest

from conftest import ACCOUNT, ALLOWED, IAM, REGION, STAGE, all_policy_files, as_list, evaluate, load, matches

COMPONENTS = [
    "execution-role",
    "permission-boundary",
    "org-scp",
    "karpenter-controller",
    "lbc-controller",
    "ebs-csi-driver",
    "external-secrets",
]

# Roles that run inside the cluster and get their permissions through EKS Pod Identity.
CONTROLLERS = ["karpenter-controller", "lbc-controller", "ebs-csi-driver", "external-secrets"]

# A sample of IAM writes. An Allow whose action pattern covers one of these by
# wildcard grants IAM writes nobody listed by hand.
IAM_WRITE_SAMPLE = [
    "iam:AttachRolePolicy",
    "iam:CreateAccessKey",
    "iam:CreatePolicy",
    "iam:CreatePolicyVersion",
    "iam:CreateRole",
    "iam:CreateUser",
    "iam:PassRole",
    "iam:PutRolePermissionsBoundary",
    "iam:PutRolePolicy",
    "iam:UpdateAssumeRolePolicy",
]
IAM_READ_PREFIXES = ("iam:get", "iam:list")

POLICY_FILES = all_policy_files()
IDS = [str(p.relative_to(IAM)) for p in POLICY_FILES]


def allow_statements(document):
    return [s for s in as_list(document["Statement"]) if s["Effect"] == "Allow"]


def test_every_component_has_a_policy():
    for component in COMPONENTS:
        assert (IAM / component / "policy.json").is_file(), f"{component}/ has no policy.json"


def test_every_controller_has_a_pod_identity_trust():
    for component in CONTROLLERS:
        assert (IAM / component / "trust.json").is_file(), f"{component}/ has no trust.json"


@pytest.mark.parametrize("path", POLICY_FILES, ids=IDS)
def test_is_valid_policy_json(path):
    document = json.loads(path.read_text())
    assert document["Version"] == "2012-10-17"
    assert as_list(document["Statement"]), "a policy needs at least one statement"
    for statement in as_list(document["Statement"]):
        assert statement["Effect"] in ("Allow", "Deny")


@pytest.mark.parametrize("path", POLICY_FILES, ids=IDS)
def test_no_allow_uses_not_action(path):
    for statement in allow_statements(json.loads(path.read_text())):
        assert "NotAction" not in statement, f"{statement.get('Sid')} allows NotAction"


@pytest.mark.parametrize("path", POLICY_FILES, ids=IDS)
def test_no_wildcard_iam_writes_and_no_iam_writes_on_every_resource(path):
    for statement in allow_statements(json.loads(path.read_text())):
        for action in as_list(statement.get("Action", [])):
            lowered = action.lower()
            if "*" in action or "?" in action:
                covered = [w for w in IAM_WRITE_SAMPLE if matches(action, w)]
                assert not covered, f"{statement.get('Sid')}: {action} is a wildcard that covers IAM writes {covered}"
            elif lowered.startswith("iam:") and not lowered.startswith(IAM_READ_PREFIXES):
                assert "*" not in as_list(statement["Resource"]), f"{statement.get('Sid')}: {action} on every resource"


@pytest.mark.parametrize("path", POLICY_FILES, ids=IDS)
def test_only_the_placeholder_account_and_region_appear(path):
    text = path.read_text()
    assert set(re.findall(r"\b\d{12}\b", text)) <= {ACCOUNT}
    regions = set(re.findall(r"\b[a-z]{2}-[a-z]+-\d\b", text))
    assert regions <= {REGION}, f"unexpected regions {regions - {REGION}}"


@pytest.mark.parametrize("path", POLICY_FILES, ids=IDS)
def test_every_json_file_is_attached_by_terraform(path):
    terraform = "\n".join(p.read_text() for p in STAGE.glob("*.tf"))
    reference = f"iam/{path.parent.name}/{path.name}"
    assert reference in terraform, f"no .tf file in iac/stage reads {reference}"


def condition_context(statement):
    """The request a controller makes: the values its own StringEquals conditions ask for."""
    context = {"aws:RequestedRegion": REGION}
    for operator in ("StringEquals", "ArnEquals"):
        for key, values in statement.get("Condition", {}).get(operator, {}).items():
            context[key] = as_list(values)[0]
    return context


@pytest.mark.parametrize("component", CONTROLLERS)
def test_the_boundary_allows_every_controller_action(component):
    boundary = load("permission-boundary")
    gaps = []
    for statement in allow_statements(load(component)):
        for action in as_list(statement["Action"]):
            for resource in as_list(statement["Resource"]):
                if evaluate([boundary], action, resource, condition_context(statement)) != ALLOWED:
                    gaps.append(f"{action} on {resource}")
    assert not gaps, f"the boundary blocks what {component} needs: {gaps}"
