#!/usr/bin/env bash
# kubeconform with every schema source pinned to a commit, so a check that
# passes today passes tomorrow. Arguments are passed through (files, dirs, -).
#   built-in kinds  yannh/kubernetes-json-schema, for the cluster's Kubernetes version
#   CRDs            datreeio/CRDs-catalog (Argo CD, Karpenter, External Secrets, ...)
# No -ignore-missing-schemas: a kind with no schema fails the check.
# kustomization.yaml files are Kustomize input, not Kubernetes objects, so skipped.
set -euo pipefail

KUBERNETES_VERSION="1.35.0"
K8S_SCHEMAS_REF="8df8a883b68a24a104b4a9e43c1288090ae60b3b"
CRD_SCHEMAS_REF="fd90051867733c60d32d16450556e9cd18459aef"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
kubeconform="${KUBECONFORM:-$repo_root/.tools/bin/kubeconform}"
cache="$repo_root/.tools/kubeconform-cache"
mkdir -p "$cache"

exec "$kubeconform" -strict -summary \
  -kubernetes-version "$KUBERNETES_VERSION" \
  -cache "$cache" \
  -ignore-filename-pattern '(^|/)kustomization\.yaml$' \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMAS_REF/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_SCHEMAS_REF/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  "$@"
