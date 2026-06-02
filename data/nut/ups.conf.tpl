# Managed by Terraform (cluster/modules/node-provision-server). Do not edit by hand.
#
# delphi-only (NUT primary). The CyberPower CP1500PFCLCD speaks USB HID; the
# generic usbhid-ups driver supports it. Match on vendorid (0764) ONLY — it's the
# only CyberPower device on the host, and pinning a productid risks "no matching
# HID UPS" if a hardware revision reports a different one. pollinterval=5 keeps
# the USB link active — CyberPower units drop the HID connection when polled lazily.

[cyberpower]
    driver = usbhid-ups
    port = auto
    vendorid = 0764
    pollinterval = 5
    desc = "CyberPower CP1500PFCLCD"

    # Shutdown trigger is runtime-adaptive, NOT a fixed wall-clock timer: assert
    # LOW BATTERY when the UPS estimates <= ${runtime_low}s of runtime remains.
    # upsmon turns OB+LB into FSD automatically. Under full GPU load this fires
    # after ~1 min on battery; at idle it may not fire for ~25 min. Short grid
    # blips never reach it — the whole point of having the UPS.
    override.battery.runtime.low = ${runtime_low}

    # On killpower, wait this long before the UPS actually cuts its outlets. The
    # primary (delphi) halts last; this delay gives the secondary (artemis) time
    # to finish its own graceful shutdown before the shared UPS load is cut.
    offdelay = 120
