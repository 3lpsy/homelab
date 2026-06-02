# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
#
# delphi-only (NUT primary). One LISTEN on 0.0.0.0 covers BOTH the local upsmon
# (connects to localhost → 127.0.0.1, served by the wildcard socket) and
# artemis's remote upsmon over delphi's LAN IP. A second `LISTEN 127.0.0.1` line
# is deliberately omitted: it overlaps the wildcard bind and upsd can fail to
# start with EADDRINUSE. Listening broadly is safe here because firewalld only
# admits 3493/tcp from the artemis source (see nut_allow_sources / the rich rule
# in the nut_primary resource), and the monitor user is password-gated read-only.
# artemis targets delphi's LAN IP, NOT the tailnet FQDN, so the shutdown signal
# survives a tailscaled hiccup and needs only the LAN switch (keep it on the UPS).
LISTEN 0.0.0.0 3493
