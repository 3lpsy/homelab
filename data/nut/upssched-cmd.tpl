#!/bin/sh
# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
# Installed as /etc/ups/upssched-cmd, 0755 root:root.
#
# Invoked by upssched (CMDSCRIPT) when one of its timers fires. The only timer is
# the wall-clock backstop from upssched.conf; on it, force a coordinated shutdown
# of the whole monitored set (primary + secondaries) via upsmon's control socket.
set -eu

case "$1" in
    onbatt-backstop)
        logger -t upssched-cmd "on-battery backstop timer fired — forcing FSD"
        /usr/sbin/upsmon -c fsd
        ;;
    *)
        logger -t upssched-cmd "unrecognized timer: $1"
        ;;
esac
