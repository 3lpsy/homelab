#!/usr/bin/env bash
# Self-heal the headscale OIDC-discovery startup deadlock.
#
# Headscale does OIDC discovery against Zitadel (oidc.<magic>, an
# in-cluster TS sidecar IP) at *startup*. That endpoint is reachable only
# over the tailnet, whose control plane is headscale itself. If the path
# to Zitadel is down, headscale fails init, exits, systemd restarts it
# (Restart=always) and it crash-loops — taking the whole tailnet control
# plane (and `terraform apply homelab`, and `headscale apikeys create`)
# down with it.
#
# The manual fix is to move the OIDC slice aside so headscale boots
# WITHOUT OIDC (tailscaled re-auths, the path to Zitadel recovers), then
# move it back once Zitadel is reachable. This script automates that
# dance as a state machine across 5-minute timer runs.
#
# Complements data/scripts/headscale-pin-oidc.sh.tpl: that pin only fixes
# DNS resolution of the issuer host; it cannot fix the TCP unreachability
# when tailscaled has no netmap because headscale is down. This watchdog
# handles that case.
#
# NB: this is a Terraform templatefile() source. Only ${magic_fqdn_suffix}
# is interpolated. Bash brace expansions ($${VAR:-default}) and the
# %%{http_code} curl format are doubled so templatefile emits them
# literally; brace-less bash vars ($LOCK, $SLICE, ...) need no escaping.
set -euo pipefail

# Paths are env-overridable (defaults are the real host paths) so the
# logic can be exercised by tests without root. Prod sets none of these.
SLICE="$${HEADSCALE_OIDC_SLICE:-/etc/headscale/_oidc.yaml}"
PARKED="$${HEADSCALE_OIDC_PARKED:-/etc/headscale/_oidc.yaml.disabled}"
PIN="$${HEADSCALE_OIDC_PIN:-/usr/local/sbin/headscale-pin-oidc.sh}"
DISCOVERY="$${HEADSCALE_OIDC_DISCOVERY:-https://oidc.${magic_fqdn_suffix}/.well-known/openid-configuration}"
LOCK="$${HEADSCALE_OIDC_LOCK:-/run/headscale-oidc-watchdog.lock}"

log(){ logger -t headscale-oidc-watchdog -- "$*"; echo "$*"; }

# Single instance — bail quietly if a prior run is still going.
exec 9>"$LOCK"
flock -n 9 || exit 0

# healthy == local API answers (gRPC up). Retry to ride out a normal restart.
healthy(){ for _ in 1 2 3; do headscale nodes list >/dev/null 2>&1 && return 0; sleep 3; done; return 1; }
zitadel_up(){ [ "$(curl -sS -m 5 -o /dev/null -w '%%{http_code}' "$DISCOVERY" || true)" = 200 ]; }
oidc_deadlock_in_log(){ journalctl -u headscale --since '-3min' 2>/dev/null \
  | grep -qiE 'openid-configuration|creating OIDC provider'; }

# ── Branch A: OIDC currently parked by a prior run ──────────────────
if [ -f "$PARKED" ] && [ ! -f "$SLICE" ]; then
  if ! healthy; then log "parked but headscale still down — non-OIDC problem; leaving for ops"; exit 1; fi
  "$PIN" || true                       # refresh oidc /etc/hosts pin now tailnet is up
  if zitadel_up; then
    log "Zitadel reachable — restoring OIDC slice"
    mv "$PARKED" "$SLICE"; systemctl restart headscale
    sleep 3; "$PIN" || true
    if healthy; then log "OIDC restored, headscale healthy"; else log "restart after restore unhealthy — next cycle re-parks"; fi
  else
    log "still OIDC-less; Zitadel unreachable, retry next cycle"
  fi
  exit 0
fi

# ── Branch B: normal (slice in place) ───────────────────────────────
if healthy; then
  [ -f "$PARKED" ] && rm -f "$PARKED"  # stale park file cleanup
  exit 0
fi
if ! oidc_deadlock_in_log; then
  log "headscale down but no OIDC-discovery error in recent log — not intervening"
  exit 0
fi
if [ ! -f "$SLICE" ]; then log "OIDC error but no slice present — nothing to park"; exit 0; fi

log "OIDC startup deadlock detected — parking OIDC slice and restarting headscale"
mv "$SLICE" "$PARKED"; systemctl restart headscale
if healthy; then
  log "headscale up OIDC-less; will restore once Zitadel reachable"
else
  log "still down after parking OIDC — escalating to ops"
fi
