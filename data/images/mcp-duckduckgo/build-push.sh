#!/usr/bin/env bash
# Build + push the mcp-duckduckgo (nickclyde DDG MCP, streamable-http) image.
#
# Usage:
#   build-push.sh [--tag <image-tag>]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAG="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

: "${REGISTRY:?REGISTRY must be set}"

image="${REGISTRY}/mcp-duckduckgo:${TAG}"

echo "==> Building ${image}"
docker build --tag "${image}" --file "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

echo "==> Pushing ${image}"
docker push "${image}"

echo "Done."
