#!/usr/bin/env bash
# Pin oidc.<magic> -> in-cluster TS IP in /etc/hosts on the headscale EC2.
#
# Without this pin, headscale's OIDC discovery resolves the issuer host
# through systemd-resolved. When tailscaled on this host is up, MagicDNS
# returns the in-cluster TS sidecar IP. When tailscaled is down (e.g.
# headscale itself crashlooped, so tailscaled couldn't re-auth), the
# resolver falls through to public DNS and hands back this EC2's own
# public IP. The request then loops into the basic-auth public proxy
# (oidc-public.nginx.conf) on the same host, gets 401, and headscale
# fails to start - a self-reinforcing deadlock.
#
# The pin makes the resolution path independent of tailscaled health.
set -euo pipefail

FQDN="oidc.${magic_fqdn_suffix}"

# headscale takes a few seconds to be ready for `nodes list` after a
# restart. Retry until the oidc node is visible.
ip=""
for _ in $(seq 1 30); do
  if ip=$(headscale nodes list -o json 2>/dev/null \
          | jq -er '.[] | select(.name=="oidc") | .ip_addresses[]' \
          | grep -E '^100\.' | head -1); then
    break
  fi
  sleep 2
done

if [ -z "$${ip}" ]; then
  echo "headscale-pin-oidc: oidc node not found in headscale" >&2
  exit 1
fi

# Idempotent rewrite: drop any prior pin line, append the fresh one.
sed -i "/[[:space:]]$${FQDN}\$/d" /etc/hosts
echo "$${ip} $${FQDN}" >> /etc/hosts
echo "headscale-pin-oidc: $${FQDN} -> $${ip}"
