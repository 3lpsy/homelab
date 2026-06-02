#!/bin/sh
# atlantic-udp-gso-fix.sh — disable the broken UDP segmentation offload on any
# NIC bound to the in-tree `atlantic` driver (Aquantia/Marvell AQC-series).
#
# Those NICs mangle GSO'd UDP super-packets, which collapses WireGuard/tailscale
# throughput to ~1 MB/s while plain TCP stays at line rate. Disabling
# tx-udp-segmentation forces correct software UDP segmentation.
#
# Driver-detected and idempotent: a no-op on hosts with no atlantic NIC (e.g.
# delphi), and exits 0 either way so the systemd oneshot stays green. Detects
# by driver rather than a hardcoded iface name so it survives renames.
set -eu

for drv in /sys/class/net/*/device/driver; do
    [ "$(basename "$(readlink "$drv")")" = atlantic ] || continue
    iface="$(basename "$(dirname "$(dirname "$drv")")")"
    echo "atlantic NIC: $iface — disabling tx-udp-segmentation"
    ethtool -K "$iface" tx-udp-segmentation off
done

exit 0
