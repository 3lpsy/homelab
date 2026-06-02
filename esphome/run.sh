#!/usr/bin/env bash
# Usage: esphome/run.sh <yaml-file> [esphome-args...]
# Default args: run (build + flash + monitor; OTA after first USB flash).
#
# Reads private values from $REPO_ROOT/.env.esphome (export VAR=val form).
# Renders esphome/secrets.yaml from secrets.yaml.tpl on every invocation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="/home/vanguard/Playground/private/envs/homelab/.env.esphome"

if [ ! -f "$ENV_FILE" ]; then
  echo "missing $ENV_FILE — copy from .env.esphome.example and fill in values" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

YAML="${1:?usage: run.sh <yaml-file> [esphome-args...]}"
shift || true

cd "$REPO_ROOT/esphome"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not installed (provided by gettext)" >&2
  exit 1
fi
envsubst < secrets.yaml.tpl > secrets.yaml

DEVICE_ARGS=()
if [ -e /dev/ttyACM0 ]; then
  DEVICE_ARGS=(--device=/dev/ttyACM0)
fi

# Pinned to 2025.10.x — newer images bundle esptool 5.x which has a known
# race in its flock() exclusive-lock path on Linux that causes
# "Resource temporarily unavailable" on USB flash. Bump cautiously.
exec podman run --rm -it \
  --group-add keep-groups \
  -v "$PWD":/config:Z \
  "${DEVICE_ARGS[@]}" \
  ghcr.io/esphome/esphome:2025.10.3 "${@:-run}" "$YAML"
