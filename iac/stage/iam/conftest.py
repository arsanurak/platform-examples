"""A small IAM evaluator for the policy tests in this folder.

It reads the policy JSON exactly as Terraform attaches it and answers one
question the way IAM would: is this call allowed, explicitly denied or
implicitly denied? It covers what these policies use: Allow and Deny,
`*` and `?` wildcards in actions and resources, NotAction and NotResource,
and the StringEquals, StringNotEquals, StringLike, ArnEquals, ArnLike,
Null and Bool conditions (with the IfExists suffix and the ForAllValues
prefix). It is not a full IAM
engine; anything it does not know fails loudly instead of guessing.
"""

import fnmatch
import json
from pathlib import Path

import pytest

IAM = Path(__file__).resolve().parent
STAGE = IAM.parent

ACCOUNT = "000000000000"
REGION = "eu-west-1"
CLUSTER = "stage"

ALLOWED = "allowed"
EXPLICIT_DENY = "explicitDeny"
IMPLICIT_DENY = "implicitDeny"


def as_list(value):
    return value if isinstance(value, list) else [value]


def matches(patterns, value, case_sensitive=False):
    """IAM-style match: `*` and `?` wildcards; actions ignore case, ARNs do not."""
    if not case_sensitive:
        return any(fnmatch.fnmatchcase(value.lower(), p.lower()) for p in as_list(patterns))
    return any(fnmatch.fnmatchcase(value, p) for p in as_list(patterns))


def _condition_holds(operator, key, expected, context):
    if operator.startswith("ForAllValues:"):
        base = operator.removeprefix("ForAllValues:")
        return all(_condition_holds(base, key, expected, {key: value}) for value in as_list(context.get(key, [])))
    if_exists = operator.endswith("IfExists")
    base = operator.removesuffix("IfExists")
    present = key in context
    actual = as_list(context.get(key, []))
    expected = [str(e).lower() if isinstance(e, bool) else str(e) for e in as_list(expected)]

    if base == "Null":
        want_missing = expected[0] == "true"
        return (not present) == want_missing
    if not present:
        return if_exists or base.startswith("StringNot") or base.startswith("ArnNot")

    def any_match(test):
        return any(test(str(a), e) for a in actual for e in expected)

    if base == "StringEquals" or base == "ArnEquals":
        return any_match(lambda a, e: a == e)
    if base == "StringNotEquals":
        return not any_match(lambda a, e: a == e)
    if base in ("StringLike", "ArnLike"):
        return any_match(lambda a, e: fnmatch.fnmatchcase(a, e))
    if base == "Bool":
        return any_match(lambda a, e: a.lower() == e)
    raise NotImplementedError(f"condition operator {operator} is not supported by this evaluator")


def _statement_applies(statement, action, resource, context):
    if "Action" in statement and not matches(statement["Action"], action):
        return False
    if "NotAction" in statement and matches(statement["NotAction"], action):
        return False
    if "Resource" in statement and not matches(statement["Resource"], resource, case_sensitive=True):
        return False
    if "NotResource" in statement and matches(statement["NotResource"], resource, case_sensitive=True):
        return False
    for operator, pairs in statement.get("Condition", {}).items():
        for key, expected in pairs.items():
            if not _condition_holds(operator, key, expected, context):
                return False
    return True


def evaluate(documents, action, resource="*", context=None):
    """Decide one call against a set of policies that all apply to the caller.

    Returns ALLOWED, EXPLICIT_DENY or IMPLICIT_DENY.
    """
    context = context or {}
    applying = [
        s
        for document in documents
        for s in as_list(document["Statement"])
        if _statement_applies(s, action, resource, context)
    ]
    if any(s["Effect"] == "Deny" for s in applying):
        return EXPLICIT_DENY
    if any(s["Effect"] == "Allow" for s in applying):
        return ALLOWED
    return IMPLICIT_DENY


def evaluate_bounded(identity, boundary, action, resource="*", context=None):
    """Decide a call for a role whose identity policies are capped by a boundary."""
    decisions = [evaluate(identity, action, resource, context), evaluate([boundary], action, resource, context)]
    if EXPLICIT_DENY in decisions:
        return EXPLICIT_DENY
    if decisions == [ALLOWED, ALLOWED]:
        return ALLOWED
    return IMPLICIT_DENY


def load(component, name="policy.json"):
    return json.loads((IAM / component / name).read_text())


def all_policy_files():
    return sorted(IAM.glob("*/*.json"))


@pytest.fixture
def policy():
    """Load one policy document: policy("org-scp") or policy("karpenter-controller", "trust.json")."""
    return load


@pytest.fixture
def decide():
    return evaluate


@pytest.fixture
def decide_bounded():
    return evaluate_bounded
