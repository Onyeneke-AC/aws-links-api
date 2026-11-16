#!/usr/bin/env bash
# Push a local image to ECR through the ECR API instead of the registry.
#
# `docker push` talks to a registry; the AWS Emulator's registry only serves
# pulls (pushes get 405 UNSUPPORTED). Underneath, a push to ECR is these API
# calls, which the emulator does implement:
#   for each blob (config + layers) not already there:
#     InitiateLayerUpload -> UploadLayerPart (10 MB parts) -> CompleteLayerUpload
#   then PutImage with the image manifest, under the tag.
# Uses whichever endpoint the AWS CLI is pointed at (`make ... EMULATOR=1`).
#
# usage: scripts/ecr-api-push.sh <local image> <repository> <tag>
set -euo pipefail

src=${1:?local image} repo=${2:?repository} tag=${3:?tag}
platform=arm64 # what the task definition runs (Graviton)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# `docker save` writes an OCI image layout: index.json -> manifest(s) -> blobs.
docker save "$src" | tar -x -C "$work"
blob() { echo "$work/blobs/sha256/${1#sha256:}"; }

# The top entry is either the image manifest or an index of per-platform
# manifests (containerd image store); pick the linux/arm64 one.
manifest=$(blob "$(jq -r '.manifests[0].digest' "$work/index.json")")
if jq -e '.manifests' "$manifest" >/dev/null; then
  digest=$(jq -r --arg p "$platform" \
    '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $p) | .digest' "$manifest")
  [ -n "$digest" ] || { echo "!! $src has no linux/$platform image" >&2; exit 1; }
  manifest=$(blob "$digest")
fi

part_mb=10
for digest in $(jq -r '.config.digest, .layers[].digest' "$manifest"); do
  available=$(aws ecr batch-check-layer-availability --repository-name "$repo" --layer-digests "$digest" \
    --query 'layers[0].layerAvailability' --output text)
  if [ "$available" = AVAILABLE ]; then
    echo "  exists   $digest"
    continue
  fi
  upload=$(aws ecr initiate-layer-upload --repository-name "$repo" --query uploadId --output text)
  file=$(blob "$digest")
  size=$(wc -c <"$file" | tr -d ' ')
  offset=0 part=0
  while [ "$offset" -lt "$size" ]; do
    dd if="$file" of="$work/part" bs=1048576 skip=$((part * part_mb)) count=$part_mb 2>/dev/null
    n=$(wc -c <"$work/part" | tr -d ' ')
    aws ecr upload-layer-part --repository-name "$repo" --upload-id "$upload" \
      --part-first-byte "$offset" --part-last-byte $((offset + n - 1)) \
      --layer-part-blob "fileb://$work/part" >/dev/null
    offset=$((offset + n)) part=$((part + 1))
  done
  aws ecr complete-layer-upload --repository-name "$repo" --upload-id "$upload" --layer-digests "$digest" >/dev/null
  echo "  uploaded $digest ($size bytes)"
done

aws ecr put-image --repository-name "$repo" --image-tag "$tag" \
  --image-manifest "file://$manifest" \
  --image-manifest-media-type "$(jq -r .mediaType "$manifest")" >/dev/null
echo ">> $repo:$tag pushed via the ECR API"
