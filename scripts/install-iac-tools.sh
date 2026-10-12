#!/usr/bin/env bash
# Install the pinned IaC check tools into .tools/ (gitignored). Safe to run more than once.
#   .tools/bin/tflint, .tools/bin/trivy   release binaries, verified against pinned SHA-256 sums
#   .tools/bin/kubeconform                the same, for the GitOps checks
#   .tools/venv                           checkov and pytest from iac/requirements.txt
#   .tools/tflint-plugins                 the tflint AWS ruleset pinned in .tflint.hcl
# CI runs this too, so local runs and CI use the same versions.
set -euo pipefail

TFLINT_VERSION="0.64.0"
TRIVY_VERSION="0.74.0"
KUBECONFORM_VERSION="0.8.0"

declare -A TFLINT_SHA256=(
  [linux_amd64]="cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537"
  [linux_arm64]="560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb"
  [darwin_amd64]="0f3a9fd17526014646a2dfc3f9122f7b4161abe3d6b0f0f03f9014483ddf4d19"
  [darwin_arm64]="2496e9cb3d24992d553b45e7c87a0fdc9449ca975233876247a9bfeda857e6c0"
)
declare -A TRIVY_SHA256=(
  [Linux-64bit]="2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a"
  [Linux-ARM64]="b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5"
  [macOS-64bit]="472816f6888dda689d075c30254d4210b4d1035acf365aa72332f584c2f60485"
  [macOS-ARM64]="1caada5e0e2091909357c7525d3aa76f4b660b13821bc143b190c7483e31cc11"
)
declare -A KUBECONFORM_SHA256=(
  [linux-amd64]="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
  [linux-arm64]="1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87"
  [darwin-amd64]="71dbc87ac9f24099a62b93570e65aa06312ba6ac8aea63b7f86e9d999edf5a92"
  [darwin-arm64]="f84f4dfbebf4a6b0b230385fa065a39ea35e02608c2b50d025dcf64775a69d67"
)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tools="${TOOLS_DIR:-$repo_root/.tools}"
python="${PYTHON:-python3}"
mkdir -p "$tools/bin"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) tflint_platform=linux_amd64; trivy_platform=Linux-64bit; go_platform=linux-amd64 ;;
  Linux-aarch64 | Linux-arm64) tflint_platform=linux_arm64; trivy_platform=Linux-ARM64; go_platform=linux-arm64 ;;
  Darwin-x86_64) tflint_platform=darwin_amd64; trivy_platform=macOS-64bit; go_platform=darwin-amd64 ;;
  Darwin-arm64) tflint_platform=darwin_arm64; trivy_platform=macOS-ARM64; go_platform=darwin-arm64 ;;
  *) echo "Unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# download URL EXPECTED_SHA256 DEST
download() {
  curl -fsSL --retry 3 -o "$3" "$1"
  local actual
  actual="$(sha256 "$3")"
  if [ "$actual" != "$2" ]; then
    echo "Checksum mismatch for $1: expected $2, got $actual" >&2
    exit 1
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! "$tools/bin/tflint" --version 2>/dev/null | grep -q "version $TFLINT_VERSION"; then
  echo "==> tflint $TFLINT_VERSION"
  download "https://github.com/terraform-linters/tflint/releases/download/v$TFLINT_VERSION/tflint_$tflint_platform.zip" \
    "${TFLINT_SHA256[$tflint_platform]}" "$work/tflint.zip"
  "$python" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("tflint", sys.argv[2])' "$work/tflint.zip" "$tools/bin"
  chmod +x "$tools/bin/tflint"
fi

if ! "$tools/bin/trivy" --version 2>/dev/null | grep -q "Version: $TRIVY_VERSION"; then
  echo "==> trivy $TRIVY_VERSION"
  download "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_$trivy_platform.tar.gz" \
    "${TRIVY_SHA256[$trivy_platform]}" "$work/trivy.tar.gz"
  tar -xzf "$work/trivy.tar.gz" -C "$tools/bin" trivy
fi

if ! "$tools/bin/kubeconform" -v 2>/dev/null | grep -q "v$KUBECONFORM_VERSION"; then
  echo "==> kubeconform $KUBECONFORM_VERSION"
  download "https://github.com/yannh/kubeconform/releases/download/v$KUBECONFORM_VERSION/kubeconform-$go_platform.tar.gz" \
    "${KUBECONFORM_SHA256[$go_platform]}" "$work/kubeconform.tar.gz"
  tar -xzf "$work/kubeconform.tar.gz" -C "$tools/bin" kubeconform
fi

requirements="$repo_root/iac/requirements.txt"
stamp="$tools/venv/.requirements.sha256"
if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$(sha256 "$requirements")" ]; then
  echo "==> checkov and pytest"
  rm -rf "$tools/venv"
  # checkov supports Python 3.9 to 3.12. Prefer uv's managed 3.12 when the local python is newer.
  if command -v uv >/dev/null; then
    uv venv --quiet --python 3.12 "$tools/venv"
    uv pip install --quiet --python "$tools/venv/bin/python" -r "$requirements"
  else
    "$python" -m venv "$tools/venv"
    "$tools/venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$requirements"
  fi
  sha256 "$requirements" >"$stamp"
fi

# The tflint AWS ruleset, at the version pinned in .tflint.hcl. tflint verifies its signature.
export TFLINT_PLUGIN_DIR="${TFLINT_PLUGIN_DIR:-$tools/tflint-plugins}"
"$tools/bin/tflint" --init --config "$repo_root/.tflint.hcl" >/dev/null

echo "IaC tools ready in $tools"
