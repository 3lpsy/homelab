# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
# Installed as /etc/ups/upsmon.conf, 0640 root:nut — carries the monitor password.
#
# artemis (NUT secondary): has no UPS of its own. It monitors delphi's upsd over
# the LAN IP (${primary_host}) — deliberately NOT the tailnet FQDN, so the
# shutdown signal survives a tailscaled hiccup on either node and needs only the
# LAN switch (which must be on the UPS too).
#
# A lost connection to delphi's upsd is NOT a shutdown trigger: after DEADTIME
# upsmon raises NOCOMM (warn only). Shutdown happens solely on an *observed*
# OB+LB or the primary's FSD flag — so a flapping network never powers artemis off.

MONITOR cyberpower@${primary_host} 1 upsmon ${monitor_password} secondary
MINSUPPLIES 1

# Graceful via kubelet's inhibitor, same as the primary (see upsmon-primary.conf).
SHUTDOWNCMD "/usr/bin/systemctl --no-wall poweroff"

HOSTSYNC 30
DEADTIME 15

NOTIFYFLAG NOCOMM  SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG COMMOK  SYSLOG+EXEC
