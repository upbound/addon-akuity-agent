#!/usr/bin/env bash
# Pull the upstream Akuity agent chart and apply the patches in patches/.
#
# The upstream chart renders the Akuity API credentials into a Secret from plain
# Helm values. Neither an AddOn package's values nor an AddOnRuntimeConfig /
# ControllerRuntimeConfig supports valuesFrom/secretRef, so shipping the chart
# unmodified would put the API key in plaintext in a CR in every control plane.
# patches/0001-existing-secret.patch adds the standard `existingSecret` idiom so
# the key can be delivered by a SharedExternalSecret instead.
#
# Usage: hack/pull-chart.sh <dest-dir>   # writes <dest-dir>/chart.tgz
set -euo pipefail

DEST="${1:?usage: pull-chart.sh <dest-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/.chart-attributes"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Pulling $REPO_URL/$CHART_NAME:$CHART_VERSION"
helm pull "$REPO_URL/$CHART_NAME" --version "$CHART_VERSION" -d "$WORK"
tar xzf "$WORK/$CHART_NAME-$CHART_VERSION.tgz" -C "$WORK"

for p in "$ROOT"/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "Applying $(basename "$p")"
  # --forward makes an already-applied patch an error rather than a prompt, so a
  # chart bump that silently changes the anchors fails the build instead of
  # shipping an unpatched chart.
  patch -p1 --forward --no-backup-if-mismatch -d "$WORK/$CHART_NAME" < "$p"
done

# Seed the Argo CD CRDs into the chart. Helm installs everything in a chart's
# crds/ directory before the templates and hooks, and `helm template
# --include-crds` emits them again at build time so the same files land in the
# package's crds/ directory.
#
# Two reasons this is here rather than left to the agent:
#   1. `up xpkg build` refuses to build a Controller package with no CRDs
#      (AtLeastOneCRD in up/internal/xpkg/lint.go). The AddOn linter does not.
#   2. The revision reconciler GETs every CRD the package declares after install
#      ("we expect the CRDs to be created by the helm chart or the application
#      itself") and fails the revision if one is missing. The Akuity agent bundle
#      creates none — confirmed both by the chart's register ClusterRole, which
#      has no apiextensions rule, and by a customer's apply log.
CRD_DIR="$WORK/$CHART_NAME/crds"
mkdir -p "$CRD_DIR"
for crd in $ARGOCD_CRDS; do
  url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/crds/${crd}.yaml"
  echo "Fetching $crd ($ARGOCD_VERSION)"
  curl -sfL "$url" -o "$CRD_DIR/${crd}.yaml"
done

mkdir -p "$DEST"
# COPYFILE_DISABLE stops macOS bsdtar from writing ._* AppleDouble entries, which
# Helm rejects with "chart illegally contains content outside the base directory".
COPYFILE_DISABLE=1 tar czf "$DEST/chart.tgz" -C "$WORK" "$CHART_NAME"
echo "Wrote $DEST/chart.tgz"
