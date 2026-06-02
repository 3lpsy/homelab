#!/bin/sh
# Block until vault is TCP-reachable from this pod.
#
# Sidesteps the kube-router netpol-ipset registration race: new pod IPs
# can take a few seconds to land in the source ipset that gates the
# cross-ns allow rule for `<consumer-ns> → vault:8201`. Until the IP is
# registered, kube-router REJECTs the SYN with `icmp-port-unreachable`
# (the iptables `REJECT` action at the bottom of the destination pod's
# firewall chain), which surfaces in Python as
# `urllib.error.URLError: <urlopen error [Errno 111] Connection refused>`.
# Scripts that call vault_login() immediately at startup race kube-router
# and crash before kube-router programs the rule.
#
# This init waits up to ~60s. If vault is genuinely down the failure is
# loud and the main container never starts.
#
# templatefile() vars (single `$`):
#   ${vault_host} — e.g. vault.<headscale_subdomain>.<headscale_magic_domain>
#                    (resolved via host_aliases pinning to the vault
#                    Service ClusterIP)
#   ${vault_port} — e.g. 8201
#
# Shell vars are escaped with `$$` so templatefile() leaves them intact.

set -eu

HOST="${vault_host}"
PORT="${vault_port}"
MAX_ATTEMPTS=30
SLEEP=2

i=0
while [ "$$i" -lt "$$MAX_ATTEMPTS" ]; do
  if nc -z "$$HOST" "$$PORT" 2>/dev/null; then
    echo "vault $$HOST:$$PORT reachable after $$i attempts"
    exit 0
  fi
  i=$$((i + 1))
  echo "attempt $$i/$$MAX_ATTEMPTS: $$HOST:$$PORT not reachable, sleeping $${SLEEP}s"
  sleep "$$SLEEP"
done

echo "FATAL: vault $$HOST:$$PORT unreachable after $$MAX_ATTEMPTS attempts (~$$((MAX_ATTEMPTS * SLEEP))s)"
exit 1
