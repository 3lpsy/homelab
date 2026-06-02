#!/usr/bin/env bash
# Build + push thunderbolt frontend/backend images to the internal registry.
#
# Usage:
#   build-push.sh [frontend|backend|all]   [--ref <git-ref>] [--tag <image-tag>]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:-all}"
shift || true

REF="main"
TAG="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)  REF="$2";  shift 2 ;;
    --tag)  TAG="$2";  shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

: "${REGISTRY:?REGISTRY must be set (e.g. registry.hs.MAGIC_DOMAIN)}"
# : "${REGISTRY_USER:?REGISTRY_USER must be set}"
# : "${REGISTRY_PASS:?REGISTRY_PASS must be set}"

# docker login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin <<<"${REGISTRY_PASS}"

build_and_push() {
  local name="$1"
  local image="${REGISTRY}/thunderbolt-${name}:${TAG}"

  echo "==> Building ${image} (ref=${REF})"
  docker build \
    --build-arg "THUNDERBOLT_REF=${REF}" \
    --tag "${image}" \
    --file "${SCRIPT_DIR}/${name}/Dockerfile" \
    "${SCRIPT_DIR}/${name}"

  echo "==> Pushing ${image}"
  docker push "${image}"
}

case "${TARGET}" in
  frontend) build_and_push frontend ;;
  backend)  build_and_push backend ;;
  all)      build_and_push frontend; build_and_push backend ;;
  *) echo "unknown target: ${TARGET} (expected frontend|backend|all)"; exit 1 ;;
esac

echo "Done."
