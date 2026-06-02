# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
#
# delphi-only. The 3-min-runtime LOW BATTERY trigger (ups.conf) is the primary
# path and needs no scheduler. This file adds ONE thing: a wall-clock backstop —
# if we've been on battery for ${onbatt_backstop_secs}s straight and the UPS
# still hasn't reported low battery (misreported runtime, stuck reading), force
# a shutdown anyway. ONLINE cancels the timer.
CMDSCRIPT /etc/ups/upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

AT ONBATT * START-TIMER onbatt-backstop ${onbatt_backstop_secs}
AT ONLINE * CANCEL-TIMER onbatt-backstop
