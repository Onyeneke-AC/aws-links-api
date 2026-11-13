#!/usr/bin/env bash
# Gates an image before it can ship. Used by the PR and main workflows.
# Usage: scripts/image-checks.sh <image:tag>
#
#   1. size budget: uncompressed size <= IMAGE_SIZE_LIMIT_MB, measured as the
#      sum of the layer sizes in `docker history`. Not `inspect .Size` (Docker
#      Desktop's containerd store over-reports it) and not `docker save` (that
#      store exports compressed layers): the history sum gives the same answer
#      on a laptop and in CI.
#   2. Trivy: fail on HIGH/CRITICAL vulnerabilities that have a fix available
set -euo pipefail

image="${1:?usage: image-checks.sh <image:tag>}"
limit_mb="${IMAGE_SIZE_LIMIT_MB:-150}"

# Aqua's own Trivy image, pinned by digest (no third-party GitHub action).
TRIVY_IMAGE="aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"

bytes=$(docker history --human=false --format '{{.Size}}' "$image" | awk '{ s += $1 } END { printf "%d", s }')
mb=$((bytes / 1000 / 1000))
echo "Image size: ${mb} MB (limit ${limit_mb} MB)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Image size: ${mb} MB (limit ${limit_mb} MB)" >> "$GITHUB_STEP_SUMMARY"
fi
if [ "$mb" -gt "$limit_mb" ]; then
  echo "FAIL: image is over the size budget" >&2
  exit 1
fi

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$TRIVY_IMAGE" \
  image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --no-progress "$image"
echo "Image checks passed"
