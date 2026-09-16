#!/usr/bin/env bash
# Mirror the one image this chart actually references into xpkg.upbound.io.
#
# NOTE: this chart only runs `akuity-cli`, which calls out to akuity.cloud and
# applies the manifests it gets back. The agent images themselves are chosen by
# Akuity at registration time and are NOT part of the chart, so they cannot be
# mirrored or pinned here. Argo CD component images can be redirected with
# `argocd.argoprojCustomImageRegistry`; there is no equivalent for the Akuity
# agent images on the argocd path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/.chart-attributes"

UP_ORG="${UP_ORG:-upbound}"

if ! command -v crane >/dev/null 2>&1; then
  echo "crane is not installed."
  exit 1
fi

SRC="quay.io/akuity/akuity-cli:${CLI_VERSION}"
DST="xpkg.upbound.io/${UP_ORG}/akuity-cli:${CLI_VERSION}"

echo "Copying $SRC -> $DST"
crane copy "$SRC" "$DST"
