# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
# Installed as /etc/ups/upsmon.conf, 0640 root:nut — carries the monitor password.
#
# delphi (NUT primary): monitors the locally-driven UPS. On OB+LB (asserted at
# <=3 min runtime via ups.conf override.battery.runtime.low) upsmon issues FSD,
# which propagates to artemis (secondary) before delphi shuts down last.

MONITOR cyberpower@localhost 1 upsmon ${monitor_password} primary
MINSUPPLIES 1

# SHUTDOWNCMD is just a poweroff — the graceful part is kubelet's systemd-logind
# inhibitor (k3s --kubelet-arg=shutdownGracePeriod), which SIGTERMs every pod
# (Vault seals, Postgres flushes) and quiesces PVC writes before the OS unmounts.
SHUTDOWNCMD "/usr/bin/systemctl --no-wall poweroff"

# Drop this flag on shutdown so the final-stage upsdrvctl shutdown cuts the UPS
# load (after offdelay) — outlets re-energize on grid return, and with BIOS
# "restore on AC = power on" both nodes auto-boot.
POWERDOWNFLAG /run/killpower

# Wait up to this long for secondaries (artemis) to report they're shutting down
# before the primary proceeds to its own shutdown.
HOSTSYNC 30

# Route notifications through upssched for the wall-clock backstop timer.
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT  SYSLOG+EXEC
NOTIFYFLAG ONLINE  SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
