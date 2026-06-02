#!/bin/bash
# Merge /etc/headscale/config.yaml (base, written by homelab) and the
# optional /etc/headscale/_oidc.yaml (OIDC slice, written by services)
# into /run/headscale/config.yaml. Headscale's ExecStart points at the
# merged file. Safe top-level concat: base has no `oidc:` key, slice has
# only `oidc:`, so combined YAML stays valid.
#
# Headscale itself does not support multi-file config (single --config
# flag, viper.ReadInConfig with no MergeInConfig). Env-var override
# cannot supply OIDC list fields (allowed_users, scope) because
# viper.GetStringSlice does not split env strings on commas — see
# spf13/viper#380. Hence this wrapper.
set -eu

BASE=/etc/headscale/config.yaml
SLICE=/etc/headscale/_oidc.yaml
OUT=/run/headscale/config.yaml

if [ ! -f "$BASE" ]; then
  echo "headscale-merge-config: $BASE missing" >&2
  exit 1
fi

if [ -f "$SLICE" ]; then
  cat "$BASE" "$SLICE" > "$OUT"
else
  cat "$BASE" > "$OUT"
fi
